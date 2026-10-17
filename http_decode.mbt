// Copyright 2026 gpui-mbt contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// M1 sans-IO HTTP/1.1 response decoder (issue 0007). Feed bytes in any
// split; the state machine reassembles exactly one response following
// upstream `ResponseAccumulator` / `read_http11_response` semantics:
// 1xx are skipped, bodies are Content-Length / chunked / close-delimited
// / empty, and a response is only produced once it is fully complete.

///|
/// Default response body limit — upstream `DOCKER_RESPONSE_BODY_LIMIT`.
pub const HTTP_RESPONSE_BODY_LIMIT : Int32 = 64 * 1024 * 1024

///|
/// Header block / header count / chunk-size-line limits. These are this
/// implementation's defensive defaults (upstream's shiguredo_http11
/// defaults were not confirmed), not upstream-verified values.
const HTTP_MAX_HEAD_BYTES : Int32 = 65536

///|
const HTTP_MAX_HEADERS : Int32 = 256

///|
const HTTP_MAX_CHUNK_LINE : Int32 = 128

///|
const HTTP_CRLF : Bytes = b"\r\n"

///|
const HTTP_HEAD_END : Bytes = b"\r\n\r\n"

///|
/// Decoded HTTP/1.1 response.
pub struct HttpResponse {
  status : Int32
  reason : String
  headers : Array[(String, String)]
  body : Bytes
}

///|
/// Every way response decoding can fail. Nothing is returned partially:
/// on error the caller must discard the connection.
pub(all) suberror HttpDecodeError {
  /// Status line is not `HTTP/x.y NNN reason`.
  MalformedStatusLine(String)
  /// A header line has no colon, an empty/invalid name, or is folded.
  MalformedHeader(String)
  /// Header block exceeded `HTTP_MAX_HEAD_BYTES`.
  HeadTooLarge
  /// More than `HTTP_MAX_HEADERS` header lines.
  TooManyHeaders
  /// Chunk size line is missing, not hex, or too long.
  InvalidChunkSize(String)
  /// Conflicting `Content-Length` values.
  InconsistentContentLength
  /// Body exceeded the configured limit (payload = limit). Uses `>`,
  /// so exactly the limit still succeeds — same boundary as upstream.
  BodyTooLarge(Int32)
  /// EOF while the response was still incomplete; payload says where.
  Truncated(String)
  /// Bytes fed after the response already completed.
  TrailingData
  /// `response()` called before completion.
  IncompleteResponse
}

///|
/// Exposes `Show`'s methods as regular methods (compiler-recommended form).
pub extend HttpDecodeError with Show::{to_string, output}

///|
pub impl Show for HttpDecodeError with fn output(self, logger) {
  let text = match self {
    MalformedStatusLine(line) => "malformed HTTP status line: \{line}"
    MalformedHeader(line) => "malformed HTTP header: \{line}"
    HeadTooLarge => "HTTP header block exceeds size limit"
    TooManyHeaders => "too many HTTP headers"
    InvalidChunkSize(line) => "invalid HTTP chunk size line: \{line}"
    InconsistentContentLength => "conflicting Content-Length headers"
    BodyTooLarge(limit) => "response body exceeds \{limit} bytes limit"
    Truncated(what) => "connection closed while \{what} was incomplete"
    TrailingData => "bytes after end of HTTP response"
    IncompleteResponse => "HTTP response is not complete yet"
  }
  logger.write_string(text)
}

///|
priv enum DecodeState {
  Head
  Fixed(Int32)
  ChunkSize
  ChunkData(Int32)
  ChunkCrlf
  Trailer
  CloseDelimited
  Done
}

///|
/// Incremental HTTP/1.1 response decoder. Not tied to any IO: feed it
/// raw bytes from any source, in any split, then call `eof()` when the
/// peer closes the connection.
pub struct HttpResponseDecoder {
  max_body : Int32
  priv mut state : DecodeState
  priv mut pending : Array[Byte]
  priv body : Array[Byte]
  priv mut status : Int32
  priv mut reason : String
  priv headers : Array[(String, String)]
}

///|
pub fn HttpResponseDecoder::new(
  max_body~ : Int32 = HTTP_RESPONSE_BODY_LIMIT,
) -> HttpResponseDecoder {
  {
    max_body,
    state: Head,
    pending: [],
    body: [],
    status: -1,
    reason: "",
    headers: [],
  }
}

///|
/// True once a complete response has been decoded.
pub fn HttpResponseDecoder::is_complete(self : HttpResponseDecoder) -> Bool {
  self.state is Done
}

///|
/// Feed the next bytes of the response. May complete the response.
pub fn HttpResponseDecoder::feed(
  self : HttpResponseDecoder,
  bytes : Bytes,
) -> Unit raise HttpDecodeError {
  if self.state is Done {
    raise HttpDecodeError::TrailingData
  }
  for b in bytes {
    self.pending.push(b)
  }
  self.drain()
}

///|
/// The peer closed the connection. Completes close-delimited bodies;
/// any other in-flight state is a `Truncated` error.
pub fn HttpResponseDecoder::eof(
  self : HttpResponseDecoder,
) -> Unit raise HttpDecodeError {
  match self.state {
    Done => ()
    CloseDelimited => {
      self.move_pending_to_body(self.pending.length())
      self.state = Done
    }
    Head =>
      raise HttpDecodeError::Truncated(
        if self.pending.is_empty() {
          "response"
        } else {
          "header block"
        },
      )
    Fixed(_) => raise HttpDecodeError::Truncated("Content-Length body")
    ChunkSize | ChunkData(_) | ChunkCrlf | Trailer =>
      raise HttpDecodeError::Truncated("chunked body")
  }
}

///|
/// The decoded response; only valid once `is_complete()`/`eof()` left
/// the decoder in the done state.
pub fn HttpResponseDecoder::response(
  self : HttpResponseDecoder,
) -> HttpResponse raise HttpDecodeError {
  if !(self.state is Done) {
    raise HttpDecodeError::IncompleteResponse
  }
  {
    status: self.status,
    reason: self.reason,
    headers: self.headers.copy(),
    body: Bytes::from_array(self.body),
  }
}

///|
/// Consume as much buffered input as the current state allows. Each
/// drain helper returns true when it made progress (consumed bytes or
/// changed state); the loop stops at the first stall.
fn HttpResponseDecoder::drain(
  self : HttpResponseDecoder,
) -> Unit raise HttpDecodeError {
  for ;; {
    let progressed = match self.state {
      Head => self.drain_head()
      Fixed(remaining) => self.drain_fixed(remaining)
      ChunkSize => self.drain_chunk_size()
      ChunkData(remaining) => self.drain_chunk_data(remaining)
      ChunkCrlf => self.drain_chunk_crlf()
      Trailer => self.drain_trailer()
      CloseDelimited => self.drain_close_delimited()
      Done => false
    }
    if !progressed {
      break
    }
  }
}

///|
fn HttpResponseDecoder::drop_front(
  self : HttpResponseDecoder,
  n : Int32,
) -> Unit {
  self.pending = self.pending[n:].to_owned()
}

///|
/// Move `n` bytes from pending into body, enforcing the body limit.
fn HttpResponseDecoder::move_pending_to_body(
  self : HttpResponseDecoder,
  n : Int32,
) -> Unit raise HttpDecodeError {
  if self.body.length() + n > self.max_body {
    raise HttpDecodeError::BodyTooLarge(self.max_body)
  }
  for i = 0; i < n; i = i + 1 {
    self.body.push(self.pending[i])
  }
  self.drop_front(n)
}

///|
fn index_of(hay : Array[Byte], needle : Bytes, from~ : Int32 = 0) -> Int32 {
  let n = needle.length()
  if hay.length() - from < n {
    return -1
  }
  for i = from; i + n <= hay.length(); i = i + 1 {
    let mut ok = true
    for j = 0; j < n; j = j + 1 {
      if hay[i + j] != needle[j] {
        ok = false
        break
      }
    }
    if ok {
      return i
    }
  }
  -1
}

///|
/// Read one `...\r\n` line out of pending, or None if incomplete.
/// Returns the line without the CRLF.
fn HttpResponseDecoder::peek_line(self : HttpResponseDecoder) -> Bytes? {
  let idx = index_of(self.pending, HTTP_CRLF)
  if idx < 0 {
    None
  } else {
    Some(Bytes::from_array(self.pending[:idx].to_owned()))
  }
}

///|
fn HttpResponseDecoder::drain_head(
  self : HttpResponseDecoder,
) -> Bool raise HttpDecodeError {
  if self.pending.length() > HTTP_MAX_HEAD_BYTES {
    raise HttpDecodeError::HeadTooLarge
  }
  let head_len = index_of(self.pending, HTTP_HEAD_END)
  if head_len < 0 {
    return false
  }
  let head = self.pending[:head_len].to_owned()
  self.drop_front(head_len + 4)
  self.parse_head(head)
  true
}

///|
/// Parse status line + headers, then either skip (1xx), finish, or
/// transition into the appropriate body state.
fn HttpResponseDecoder::parse_head(
  self : HttpResponseDecoder,
  head : Array[Byte],
) -> Unit raise HttpDecodeError {
  let lines = split_lines(head)
  if lines.is_empty() {
    raise HttpDecodeError::MalformedStatusLine("<empty>")
  }
  let (status, reason) = parse_status_line(lines[0])
  let headers : Array[(String, String)] = []
  for i = 1; i < lines.length(); i = i + 1 {
    if headers.length() >= HTTP_MAX_HEADERS {
      raise HttpDecodeError::TooManyHeaders
    }
    headers.push(parse_header_line(lines[i]))
  }
  // 1xx are discarded wholesale; the real response follows.
  if status >= 100 && status < 200 {
    return
  }
  self.status = status
  self.reason = reason
  for pair in headers {
    self.headers.push(pair)
  }
  if status == 204 || status == 304 {
    self.state = Done
    return
  }
  let chunked = transfer_encoding_is_chunked(headers)
  let lengths = content_lengths(headers, self.max_body)
  match (chunked, lengths) {
    (true, _) => self.state = ChunkSize
    (false, []) => self.state = CloseDelimited
    (false, [n]) =>
      if n > self.max_body {
        raise HttpDecodeError::BodyTooLarge(self.max_body)
      } else if n == 0 {
        self.state = Done
      } else {
        self.state = Fixed(n)
      }
    (false, _) => raise HttpDecodeError::InconsistentContentLength
  }
}

///|
fn HttpResponseDecoder::drain_fixed(
  self : HttpResponseDecoder,
  remaining : Int32,
) -> Bool raise HttpDecodeError {
  if remaining == 0 {
    self.state = Done
    return true
  }
  if self.pending.is_empty() {
    return false
  }
  let n = if self.pending.length() < remaining {
    self.pending.length()
  } else {
    remaining
  }
  self.move_pending_to_body(n)
  self.state = Fixed(remaining - n)
  true
}

///|
fn HttpResponseDecoder::drain_chunk_size(
  self : HttpResponseDecoder,
) -> Bool raise HttpDecodeError {
  match self.peek_line() {
    None => {
      if self.pending.length() > HTTP_MAX_CHUNK_LINE {
        raise HttpDecodeError::InvalidChunkSize("<over-long line>")
      }
      false
    }
    Some(line) => {
      self.drop_front(line.length() + 2)
      let n = parse_chunk_size(line)
      if n == 0 {
        self.state = Trailer
      } else {
        self.state = ChunkData(n)
      }
      true
    }
  }
}

///|
fn HttpResponseDecoder::drain_chunk_data(
  self : HttpResponseDecoder,
  remaining : Int32,
) -> Bool raise HttpDecodeError {
  if self.pending.is_empty() {
    return false
  }
  let n = if self.pending.length() < remaining {
    self.pending.length()
  } else {
    remaining
  }
  self.move_pending_to_body(n)
  self.state = if remaining - n == 0 {
    ChunkCrlf
  } else {
    ChunkData(remaining - n)
  }
  true
}

///|
fn HttpResponseDecoder::drain_chunk_crlf(
  self : HttpResponseDecoder,
) -> Bool raise HttpDecodeError {
  if self.pending.length() < 2 {
    return false
  }
  if self.pending[0] != b'\r' || self.pending[1] != b'\n' {
    raise HttpDecodeError::InvalidChunkSize("chunk data not terminated by CRLF")
  }
  self.drop_front(2)
  self.state = ChunkSize
  true
}

///|
/// Trailer lines are read and discarded until the empty line.
fn HttpResponseDecoder::drain_trailer(
  self : HttpResponseDecoder,
) -> Bool raise HttpDecodeError {
  match self.peek_line() {
    None => {
      if self.pending.length() > HTTP_MAX_CHUNK_LINE {
        raise HttpDecodeError::InvalidChunkSize("<over-long trailer line>")
      }
      false
    }
    Some(line) => {
      self.drop_front(line.length() + 2)
      if line.length() == 0 {
        self.state = Done
      }
      true
    }
  }
}

///|
fn HttpResponseDecoder::drain_close_delimited(
  self : HttpResponseDecoder,
) -> Bool raise HttpDecodeError {
  if self.pending.is_empty() {
    return false
  }
  self.move_pending_to_body(self.pending.length())
  true
}

///|
/// Split a header block (no trailing CRLFCRLF) at every CRLF.
fn split_lines(head : Array[Byte]) -> Array[Array[Byte]] {
  let lines : Array[Array[Byte]] = []
  let mut start = 0
  let mut i = 0
  while i + 1 < head.length() {
    if head[i] == b'\r' && head[i + 1] == b'\n' {
      lines.push(head[start:i].to_owned())
      start = i + 2
      i = i + 2
    } else {
      i = i + 1
    }
  }
  lines.push(head[start:].to_owned())
  lines
}

///|
/// `HTTP/x.y NNN reason` — version token, 3-digit status, optional reason.
fn parse_status_line(
  line : Array[Byte],
) -> (Int32, String) raise HttpDecodeError {
  let text = @utf8.decode_lossy(Bytes::from_array(line))
  let sp1 = index_of(line, b" ")
  if sp1 < 0 || sp1 < 6 {
    raise HttpDecodeError::MalformedStatusLine(text)
  }
  // version: must be HTTP/<something>
  let version = line[:sp1].to_owned()
  guard version.length() > 5 &&
    version[0] == b'H' &&
    version[1] == b'T' &&
    version[2] == b'T' &&
    version[3] == b'P' &&
    version[4] == b'/' else {
    raise HttpDecodeError::MalformedStatusLine(text)
  }
  // status: exactly 3 digits
  let rest = sp1 + 1
  guard rest + 3 <= line.length() &&
    is_digit(line[rest]) &&
    is_digit(line[rest + 1]) &&
    is_digit(line[rest + 2]) else {
    raise HttpDecodeError::MalformedStatusLine(text)
  }
  let status = (line[rest].to_int() - '0'.to_int()) * 100 +
    (line[rest + 1].to_int() - '0'.to_int()) * 10 +
    (line[rest + 2].to_int() - '0'.to_int())
  let mut reason = ""
  if rest + 3 < line.length() {
    guard line[rest + 3] == b' ' else {
      raise HttpDecodeError::MalformedStatusLine(text)
    }
    reason = @utf8.decode_lossy(Bytes::from_array(line[rest + 4:].to_owned()))
  }
  (status, reason)
}

///|
fn is_digit(b : Byte) -> Bool {
  b >= b'0' && b <= b'9'
}

///|
fn is_tchar(b : Byte) -> Bool {
  is_digit(b) ||
  (b >= b'a' && b <= b'z') ||
  (b >= b'A' && b <= b'Z') ||
  b == b'!' ||
  b == b'#' ||
  b == b'$' ||
  b == b'%' ||
  b == b'&' ||
  b == b'\'' ||
  b == b'*' ||
  b == b'+' ||
  b == b'-' ||
  b == b'.' ||
  b == b'^' ||
  b == b'_' ||
  b == b'`' ||
  b == b'|' ||
  b == b'~'
}

///|
/// `Name: value` — name must be a non-empty tchar token, value is
/// stripped of optional whitespace. Obs-fold lines (leading whitespace)
/// are rejected.
fn parse_header_line(
  line : Array[Byte],
) -> (String, String) raise HttpDecodeError {
  if line.is_empty() {
    raise HttpDecodeError::MalformedHeader("<empty line>")
  }
  if line[0] == b' ' || line[0] == b'\t' {
    raise HttpDecodeError::MalformedHeader("obs-fold is not supported")
  }
  let colon = index_of(line, b":")
  if colon <= 0 {
    raise HttpDecodeError::MalformedHeader(
      @utf8.decode_lossy(Bytes::from_array(line)),
    )
  }
  let name_bytes = line[:colon].to_owned()
  for b in name_bytes {
    if !is_tchar(b) {
      raise HttpDecodeError::MalformedHeader(
        @utf8.decode_lossy(Bytes::from_array(line)),
      )
    }
  }
  let mut vstart = colon + 1
  let mut vend = line.length()
  while vstart < vend && (line[vstart] == b' ' || line[vstart] == b'\t') {
    vstart = vstart + 1
  }
  while vend > vstart && (line[vend - 1] == b' ' || line[vend - 1] == b'\t') {
    vend = vend - 1
  }
  (
    @utf8.decode_lossy(Bytes::from_array(name_bytes)),
    @utf8.decode_lossy(Bytes::from_array(line[vstart:vend].to_owned())),
  )
}

///|
/// Lowercase-ascii a header name/value for comparison.
fn ascii_lower(s : String) -> String {
  let buf = StringBuilder()
  for c in s {
    if c >= 'A' && c <= 'Z' {
      buf.write_char((c.to_int() + 32).unsafe_to_char())
    } else {
      buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
/// True when `Transfer-Encoding` ends in `chunked`. A `chunked` token
/// that is not last is a smuggling red flag and treated as malformed by
/// making the response undeodable... it is rejected via InconsistentLength-free
/// path: we simply do not treat it as chunked, which is then a parse
/// error downstream iff a CL conflicts. Keep it simple: last-token check.
fn transfer_encoding_is_chunked(headers : Array[(String, String)]) -> Bool {
  for pair in headers {
    if ascii_lower(pair.0) == "transfer-encoding" {
      let tokens = pair.1
        .split(",")
        .iter()
        .map(fn(t) { ascii_lower(t.trim().to_owned()) })
        .collect()
      if tokens.length() > 0 && tokens[tokens.length() - 1] == "chunked" {
        return true
      }
    }
  }
  false
}

///|
/// Parse a chunk-size line: hex digits optionally followed by `;` and
/// chunk extensions (ignored). Raises on empty/non-hex/overflow.
fn parse_chunk_size(line : Bytes) -> Int32 raise HttpDecodeError {
  let text = @utf8.decode_lossy(line)
  let mut n = 0
  let mut saw_digit = false
  for b in line {
    if b == b';' {
      break
    }
    let d = if b >= b'0' && b <= b'9' {
      b.to_int() - '0'.to_int()
    } else if b >= b'a' && b <= b'f' {
      b.to_int() - 'a'.to_int() + 10
    } else if b >= b'A' && b <= b'F' {
      b.to_int() - 'A'.to_int() + 10
    } else {
      raise HttpDecodeError::InvalidChunkSize(text)
    }
    saw_digit = true
    if n > (0x7fffffff - 15) / 16 {
      raise HttpDecodeError::InvalidChunkSize("chunk size overflows: \{text}")
    }
    n = n * 16 + d
  }
  if !saw_digit {
    raise HttpDecodeError::InvalidChunkSize(text)
  }
  n
}

///|
/// Distinct Content-Length values, or raise on a non-integer value.
/// Values are clamped at `limit + 1` to avoid Int overflow; the real
/// boundary check (`>` limit) happens in `parse_head`.
fn content_lengths(
  headers : Array[(String, String)],
  limit : Int32,
) -> Array[Int32] raise HttpDecodeError {
  let out : Array[Int32] = []
  for pair in headers {
    if ascii_lower(pair.0) == "content-length" {
      let v = pair.1.trim().to_owned()
      if v.is_empty() {
        raise HttpDecodeError::MalformedHeader("empty Content-Length")
      }
      let mut n = 0
      for c in v {
        guard c is ('0'..<='9') else {
          raise HttpDecodeError::MalformedHeader(
            "non-numeric Content-Length: \{v}",
          )
        }
        n = n * 10 + c.to_int() - '0'.to_int()
        if n > limit {
          n = limit + 1
          break
        }
      }
      if !out.contains(n) {
        out.push(n)
      }
    }
  }
  out
}
