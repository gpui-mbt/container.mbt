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

// M1 Docker log delivery (issue 0013). Ports upstream
// `docker_log_stream.rs`: a 1-shot `GET /containers/{id}/logs`
// (follow=false, whole body bounded at 64 MiB) and a follow session
// (follow=true) whose per-stream buffers are capped at 8 MiB with
// drop-oldest semantics. `DockerLogSession::stop()` issues
// `shutdown(SHUT_RDWR)` on the session socket — upstream
// `try_clone + shutdown(Both)` — which wakes a blocked reader with EOF
// without closing the fd underneath it. Callers stop sessions before
// `stop_container`/`remove_container` (upstream `stop_log_delivery`).

///|
/// Per-stream buffer cap for follow sessions — upstream
/// `DEFAULT_BUFFER_LIMIT` (8 MiB). Beyond the cap the oldest bytes are
/// dropped; `*_dropped` counters make the loss observable.
pub const LOG_BUFFER_LIMIT : Int32 = 8 * 1024 * 1024

///|
/// Bound for session startup (connect + request + response head) —
/// upstream `LOG_SESSION_TIMEOUT`. Released once the head is read:
/// a follow stream may legitimately produce no output for hours.
const LOG_SESSION_TIMEOUT_MS : Int32 = 30_000

///|
/// Bounded per-stream buffer for a follow session. Appends past
/// `limit` evict the oldest bytes (drop-oldest); `dropped` counts how
/// many bytes were lost so consumers can detect gaps.
priv struct LogBuffer {
  limit : Int32
  mut data : Array[Byte]
  mut dropped : Int64
}

///|
fn LogBuffer::new(limit : Int32) -> LogBuffer {
  { limit, data: [], dropped: 0L, }
}

///|
fn LogBuffer::push(self : LogBuffer, bytes : Bytes) -> Unit {
  for b in bytes {
    self.data.push(b)
  }
  let over = self.data.length() - self.limit
  if over > 0 {
    self.data = self.data[over:].to_owned()
    self.dropped = self.dropped + over.to_int64()
  }
}

///|
/// Incremental Docker multiplexed-frame parser. Feed de-chunked body
/// bytes; `drain` yields complete frames; `finish` (at EOF) emits a
/// truncated trailing payload like `demux_exec_stream` (upstream
/// tolerance) and discards a truncated header (<8 bytes).
priv struct FrameSink {
  mut pending : Array[Byte]
}

///|
fn FrameSink::new() -> FrameSink {
  { pending: [], }
}

///|
/// Pop all complete frames as `(stream_type, payload)`.
fn FrameSink::drain(self : FrameSink) -> Array[(Int32, Bytes)] {
  let out : Array[(Int32, Bytes)] = []
  for ;; {
    if self.pending.length() < 8 {
      break
    }
    let len64 = (self.pending[4].to_int().to_int64() << 24) |
      (self.pending[5].to_int().to_int64() << 16) |
      (self.pending[6].to_int().to_int64() << 8) |
      self.pending[7].to_int().to_int64()
    let end64 = 8L + len64
    if end64 > self.pending.length().to_int64() {
      break
    }
    let end = end64.to_int()
    out.push(
      (
        self.pending[0].to_int(),
        Bytes::from_array(self.pending[8:end].to_owned()),
      ),
    )
    self.pending = self.pending[end:].to_owned()
  }
  out
}

///|
/// EOF flush: a final truncated payload keeps the bytes it received
/// (same rule as `demux_exec_stream`); a partial header is dropped.
fn FrameSink::finish(self : FrameSink) -> (Int32, Bytes)? {
  if self.pending.length() < 8 {
    return None
  }
  let len64 = (self.pending[4].to_int().to_int64() << 24) |
    (self.pending[5].to_int().to_int64() << 16) |
    (self.pending[6].to_int().to_int64() << 8) |
    self.pending[7].to_int().to_int64()
  let end64 = 8L + len64
  let end = if end64 < self.pending.length().to_int64() {
    end64.to_int()
  } else {
    self.pending.length()
  }
  Some(
    (
      self.pending[0].to_int(),
      Bytes::from_array(self.pending[8:end].to_owned()),
    ),
  )
}

///|
fn FrameSink::feed(self : FrameSink, bytes : Bytes) -> Array[(Int32, Bytes)] {
  for b in bytes {
    self.pending.push(b)
  }
  self.drain()
}

///|
/// A live follow subscription on `GET /containers/{id}/logs?follow=true`.
/// Created before the reader task; `follow_logs` fills in the socket.
/// Two end paths, per the issue's consumer-cancel rule:
/// `session.stop()` (active `shutdown`) and task cancellation (the
/// reader's `defer` always closes the fd and marks `ended`).
pub struct DockerLogSession {
  /// Container id the session follows.
  id : String
  priv stdout_buf : LogBuffer
  priv stderr_buf : LogBuffer
  priv mut sock : UnixSocket?
  priv mut stopped : Bool
  priv mut ended : Bool
  /// Any error that terminated the session (startup classification or
  /// mid-stream failure); `None` for clean EOF/stop.
  priv mut failure : Error?
}

///|
/// Buffer cap per stream is injectable so tests can exercise
/// drop-oldest without producing 8 MiB of output.
pub fn DockerLogSession::new(
  id~ : String,
  buffer_limit~ : Int32 = LOG_BUFFER_LIMIT,
) -> DockerLogSession {
  {
    id,
    stdout_buf: LogBuffer::new(buffer_limit),
    stderr_buf: LogBuffer::new(buffer_limit),
    sock: None,
    stopped: false,
    ended: false,
    failure: None,
  }
}

///|
/// Snapshot of the retained stdout window (last ≤8 MiB written).
pub fn DockerLogSession::stdout(self : DockerLogSession) -> Bytes {
  Bytes::from_array(self.stdout_buf.data)
}

///|
/// Snapshot of the retained stderr window.
pub fn DockerLogSession::stderr(self : DockerLogSession) -> Bytes {
  Bytes::from_array(self.stderr_buf.data)
}

///|
/// Bytes evicted from the front of the stdout window by drop-oldest.
pub fn DockerLogSession::stdout_dropped(self : DockerLogSession) -> Int64 {
  self.stdout_buf.dropped
}

///|
/// Bytes evicted from the front of the stderr window by drop-oldest.
pub fn DockerLogSession::stderr_dropped(self : DockerLogSession) -> Int64 {
  self.stderr_buf.dropped
}

///|
/// The terminating error, or `None` for a clean EOF/stop.
pub fn DockerLogSession::error(self : DockerLogSession) -> Error? {
  self.failure
}

///|
/// True once the reader task has fully ended (socket closed).
pub fn DockerLogSession::is_ended(self : DockerLogSession) -> Bool {
  self.ended
}

///|
/// End the subscription: flags the reader out and issues
/// `shutdown(SHUT_RDWR)` so a blocked read wakes with EOF. Safe before
/// connect (the flag alone ends it) and safe to call twice.
pub fn DockerLogSession::stop(self : DockerLogSession) -> Unit {
  self.stopped = true
  if self.sock is Some(s) {
    s.shutdown()
  }
}

///|
/// Append demuxed frames to the per-stream buffers; type 0 (stdin) and
/// unknown types are dropped, matching `demux_exec_stream`.
fn DockerLogSession::absorb(
  self : DockerLogSession,
  frames : Array[(Int32, Bytes)],
) -> Unit {
  for (ty, payload) in frames {
    if ty == 1 {
      self.stdout_buf.push(payload)
    } else if ty == 2 {
      self.stderr_buf.push(payload)
    }
  }
}

///|
/// Result of a 1-shot (follow=false) logs fetch.
pub struct DockerLogs {
  stdout : Bytes
  stderr : Bytes
}

///|
/// Body framing for the post-head stream: Docker serves logs as
/// close-delimited or chunked depending on version/proxy.
priv enum LogFraming {
  Chunked
  Fixed(Int64)
  CloseDelimited
}

///|
/// Minimal head parse for the streaming path: status code, framing,
/// and the multiplexed-content-type rule (upstream
/// `is_multiplex_content_type`: allow `vnd.docker.multiplexed-stream`,
/// `application/octet-stream`, or no Content-Type; reject the raw TTY
/// `application/vnd.docker.raw-stream` and anything else).
fn parse_log_head(head : String, op~ : String) -> (Int32, LogFraming) raise {
  let lines = head.split("\r\n").collect()
  guard lines.length() > 0 else {
    raise EngineError::MalformedResponse(op~, detail="empty log response head")
  }
  let status : Int32 = {
    let parts = lines[0].split(" ").collect()
    guard parts.length() >= 2 else {
      raise EngineError::MalformedResponse(
        op~,
        detail="malformed log status line",
      )
    }
    let mut n = 0
    let mut ok = parts[1].length() == 3
    for c in parts[1] {
      if c is ('0'..<='9') {
        n = n * 10 + (c.to_int() - '0'.to_int())
      } else {
        ok = false
      }
    }
    guard ok else {
      raise EngineError::MalformedResponse(
        op~,
        detail="malformed log status line",
      )
    }
    n
  }
  let mut chunked = false
  let mut content_length : Int64? = None
  for i = 1; i < lines.length(); i = i + 1 {
    let line = lines[i]
    let lower = ascii_lower(line.to_owned())
    if lower.has_prefix("content-type:") {
      let value = ascii_lower(line[13:].to_owned().trim().to_owned())
      guard value.is_empty() ||
        value.contains("application/vnd.docker.multiplexed-stream") ||
        value.contains("application/octet-stream") else {
        raise EngineError::MalformedResponse(
          op~,
          detail="log stream is a raw TTY stream, not multiplexed",
        )
      }
    } else if lower.has_prefix("transfer-encoding:") {
      if lower.contains("chunked") {
        chunked = true
      }
    } else if lower.has_prefix("content-length:") {
      let mut n = 0L
      let mut ok = false
      for c in line[15:] {
        if c is ('0'..<='9') {
          n = n * 10L + (c.to_int() - '0'.to_int()).to_int64()
          ok = true
        }
      }
      if ok {
        content_length = Some(n)
      }
    }
  }
  let framing = if chunked {
    LogFraming::Chunked
  } else if content_length is Some(n) {
    LogFraming::Fixed(n)
  } else {
    LogFraming::CloseDelimited
  }
  (status, framing)
}

///|
/// De-chunked body → demuxed frames → session buffers, until EOF or
/// `session.stop()`. Runs without a per-read deadline: follow streams
/// legitimately idle; termination comes from the daemon closing, a
/// caller `DeadlineExceeded` only if one was passed and is checked at
/// each iteration, or `stop()`.
async fn pump_log_body(
  conn : UnixSocket,
  session : DockerLogSession,
  framing : LogFraming,
  deadline? : Deadline,
) -> Unit {
  let demux = FrameSink::new()
  match framing {
    CloseDelimited =>
      for ;; {
        if session.stopped {
          break
        }
        let chunk = match deadline {
          None => conn.read_some()
          Some(d) => d.run(op="logs", () => conn.read_some())
        }
        match chunk {
          Some(bytes) => session.absorb(demux.feed(bytes))
          None => break
        }
      }
    Fixed(total) => {
      let mut left = total
      while left > 0L && !session.stopped {
        let chunk = match deadline {
          None => conn.read_some()
          Some(d) => d.run(op="logs", () => conn.read_some())
        }
        match chunk {
          Some(bytes) => {
            left = left - bytes.length().to_int64()
            session.absorb(demux.feed(bytes))
          }
          None => break
        }
      }
    }
    Chunked =>
      for ;; {
        if session.stopped {
          break
        }
        let line = match deadline {
          None => conn.read_until("\r\n")
          Some(d) => d.run(op="logs", () => conn.read_until("\r\n"))
        }
        guard line is Some(l) else { break }
        let size = try
          parse_chunk_size(@utf8.encode(l.trim().to_owned()))
        catch {
          _ => break
        } noraise {
          s => s
        }
        if size == 0 {
          break
        }
        let payload = try {
          match deadline {
            None => conn.read_exactly(size)
            Some(d) => d.run(op="logs", () => conn.read_exactly(size))
          }
        } catch {
          _ => break
        } noraise {
          p => p
        }
        session.absorb(demux.feed(payload))
        // Consume the chunk-terminating CRLF; a missing one ends the
        // session rather than misaligning the frame stream.
        let crlf = try {
          match deadline {
            None => conn.read_exactly(2)
            Some(d) => d.run(op="logs", () => conn.read_exactly(2))
          }
        } catch {
          _ => break
        } noraise {
          b => b
        }
        if crlf.length() != 2 {
          break
        }
      }
  }
  if demux.finish() is Some(frame) {
    session.absorb([frame])
  }
}

///|
/// Follow `GET /containers/{id}/logs?stdout=1&stderr=1&follow=true&
/// tail=all` — meant to run inside the caller's task group
/// (`group.spawn_bg(() => client.follow_logs(session))`). Never raises:
/// every terminating condition lands in `session.error()`, and
/// `session.is_ended()` flips once the socket is closed. Startup
/// (connect + request + response head) is bounded by
/// `min(30 s, deadline)`; after the head there is no per-read timeout.
pub async fn DockerClient::follow_logs(
  self : DockerClient,
  session : DockerLogSession,
  deadline? : Deadline,
) -> Unit {
  try self.follow_logs_inner(session, deadline?) catch {
    e => session.failure = Some(e)
  } noraise {
    _ => ()
  }
}

///|
async fn DockerClient::follow_logs_inner(
  self : DockerClient,
  session : DockerLogSession,
  deadline? : Deadline,
) -> Unit {
  let start_ms = match deadline {
    None => LOG_SESSION_TIMEOUT_MS
    Some(d) => {
      let r = d.remaining_ms().to_int()
      if r < LOG_SESSION_TIMEOUT_MS {
        r
      } else {
        LOG_SESSION_TIMEOUT_MS
      }
    }
  }
  let start = Deadline::after(start_ms)
  let conn = self.send_request(
    verb="GET",
    path="/containers/\{percent_encode(session.id)}/logs?stdout=1&stderr=1&follow=true&tail=all",
    op="logs",
    deadline=start,
  )
  session.sock = Some(conn)
  defer {
    conn.close()
    session.ended = true
  }
  if session.stopped {
    return
  }
  let head = start.run(op="logs", () => conn.read_until("\r\n\r\n"))
  guard head is Some(h) else {
    raise EngineError::MalformedResponse(
      op="logs",
      detail="empty log response head",
    )
  }
  let (status, framing) = parse_log_head(h, op="logs")
  guard status >= 200 && status < 300 else {
    let body = try conn.read_all() catch {
      _ => b""
    } noraise {
      b => b
    }
    raise classify_engine_error(
      op="logs",
      context=EngineOp::container_lifecycle(),
      status~,
      body~,
      target=session.id,
    )
  }
  pump_log_body(conn, session, framing, deadline?)
}

///|
/// `GET /containers/{id}/logs?stdout=1&stderr=1&follow=false&tail=..`
/// — one request, whole body decoded under `body_limit` (default the
/// shared 64 MiB `HTTP_RESPONSE_BODY_LIMIT`), then demuxed. The
/// multiplexed content-type rule is the same as follow's: a raw TTY
/// stream is an explicit `MalformedResponse`, never frame-decoded.
pub async fn DockerClient::logs(
  self : DockerClient,
  id : String,
  tail~ : String = "all",
  body_limit~ : Int32 = HTTP_RESPONSE_BODY_LIMIT,
  deadline? : Deadline,
) -> DockerLogs {
  let resp = self.request(
    verb="GET",
    path="/containers/\{percent_encode(id)}/logs?stdout=1&stderr=1&follow=false&tail=\{percent_encode(tail)}",
    op="logs",
    context=EngineOp::container_lifecycle(),
    target=id,
    body_limit~,
    deadline?,
  )
  for (name, value) in resp.headers {
    if ascii_lower(name) == "content-type" &&
      !(value.is_empty() ||
      value.contains("application/vnd.docker.multiplexed-stream") ||
      value.contains("application/octet-stream")) {
      raise EngineError::MalformedResponse(
        op="logs",
        detail="log stream is a raw TTY stream, not multiplexed",
      )
    }
  }
  let (stdout, stderr) = demux_exec_stream(resp.body)
  { stdout, stderr, }
}
