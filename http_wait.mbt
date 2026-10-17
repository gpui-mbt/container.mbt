///|
/// HTTP/1.1 readiness wait (issue 0036) — the MoonBit counterpart of
/// upstream `HttpWaitStrategy`. Plain TCP only: TLS handshakes decode
/// as `NonHttp` and retry until the shared deadline, never a false
/// positive ready signal.

///|
/// Per-request body cap for matching — larger bodies are truncated,
/// not fatal (upstream `MAX_HTTP_RESPONSE_BODY_BYTES`).
pub const HTTP_WAIT_BODY_CAP : Int32 = 1048576 // 1 MiB

///|
/// Poll interval / request timeout defaults (upstream: 100ms / 10s).
pub const HTTP_WAIT_POLL_MS : Int32 = 100

///|
pub const HTTP_WAIT_REQUEST_TIMEOUT_MS : Int32 = 10_000

///|
/// What to send and what counts as ready.
pub struct HttpWaitStrategy {
  path : String
  /// container port to poll; None selects the first published port
  port : Int32?
  verb : String
  request_headers : Array[(String, String)]
  request_body : Bytes
  expected_status : Int32?
  expected_headers : Array[(String, String)]
  expected_body : String?
  poll_interval_ms : Int32
  request_timeout_ms : Int32
}

///|
pub fn HttpWaitStrategy::new(path : String) -> HttpWaitStrategy {
  {
    path,
    port: None,
    verb: "GET",
    request_headers: [],
    request_body: b"",
    expected_status: None,
    expected_headers: [],
    expected_body: None,
    poll_interval_ms: HTTP_WAIT_POLL_MS,
    request_timeout_ms: HTTP_WAIT_REQUEST_TIMEOUT_MS,
  }
}

///|
/// Poll this container port (upstream `with_port`).
pub fn HttpWaitStrategy::with_port(
  self : HttpWaitStrategy,
  port : Int32,
) -> HttpWaitStrategy {
  { ..self, port: Some(port), }
}

///|
/// HTTP method for the probe (default GET).
pub fn HttpWaitStrategy::with_verb(
  self : HttpWaitStrategy,
  verb : String,
) -> HttpWaitStrategy {
  { ..self, verb, }
}

///|
/// Additional request header; reserved names (Host, Connection,
/// Content-Length, Authorization) are skipped at build time.
pub fn HttpWaitStrategy::with_request_header(
  self : HttpWaitStrategy,
  name : String,
  value : String,
) -> HttpWaitStrategy {
  let next = { ..self, request_headers: self.request_headers.copy(), }
  next.request_headers.push((name, value))
  next
}

///|
/// Request body for the probe.
pub fn HttpWaitStrategy::with_request_body(
  self : HttpWaitStrategy,
  body : Bytes,
) -> HttpWaitStrategy {
  { ..self, request_body: body, }
}

///|
/// Succeed when the response has this status (upstream
/// `with_expected_status_code`).
pub fn HttpWaitStrategy::with_expected_status(
  self : HttpWaitStrategy,
  status : Int32,
) -> HttpWaitStrategy {
  { ..self, expected_status: Some(status), }
}

///|
/// Succeed when the response carries this exact header (name is
/// matched case-insensitively).
pub fn HttpWaitStrategy::with_expected_header(
  self : HttpWaitStrategy,
  name : String,
  value : String,
) -> HttpWaitStrategy {
  let next = { ..self, expected_headers: self.expected_headers.copy(), }
  next.expected_headers.push((name, value))
  next
}

///|
/// Succeed when the response body contains this substring.
pub fn HttpWaitStrategy::with_expected_body(
  self : HttpWaitStrategy,
  body : String,
) -> HttpWaitStrategy {
  { ..self, expected_body: Some(body), }
}

///|
pub fn HttpWaitStrategy::with_poll_interval(
  self : HttpWaitStrategy,
  ms : Int32,
) -> HttpWaitStrategy {
  { ..self, poll_interval_ms: ms, }
}

///|
pub fn HttpWaitStrategy::with_request_timeout(
  self : HttpWaitStrategy,
  ms : Int32,
) -> HttpWaitStrategy {
  { ..self, request_timeout_ms: ms, }
}

///|
/// Any matcher at all — without one the wait would have nothing to
/// check and is a configuration error (upstream rule).
fn HttpWaitStrategy::has_matcher(self : HttpWaitStrategy) -> Bool {
  self.expected_status is Some(_) ||
  self.expected_headers.length() > 0 ||
  self.expected_body is Some(_)
}

///|
/// Headers the request builder owns — user-supplied duplicates are
/// skipped (upstream warns; we just drop, the wire test asserts it).
fn is_reserved_header(name : String) -> Bool {
  let n = ascii_lower(name)
  n == "host" ||
  n == "connection" ||
  n == "content-length" ||
  n == "authorization"
}

///|
/// Serialize the probe request. `host`/`port` produce the Host header
/// (IPv6 wrapped in brackets), Connection: close is forced, and a
/// non-empty body gets Content-Length.
fn build_http_probe(s : HttpWaitStrategy, host : String, port : Int32) -> Bytes {
  let host_header = if host.contains(":") {
    "[\{host}]:\{port}"
  } else {
    "\{host}:\{port}"
  }
  let mut out = "\{s.verb} \{s.path} HTTP/1.1\r\nHost: \{host_header}\r\nConnection: close\r\n"
  for (k, v) in s.request_headers {
    if is_reserved_header(k) {
      continue
    }
    out += "\{k}: \{v}\r\n"
  }
  if s.request_body.length() > 0 {
    out += "Content-Length: \{s.request_body.length()}\r\n"
  }
  out += "\r\n"
  let head = @utf8.encode(out)
  if s.request_body.is_empty() {
    head
  } else {
    let buf = FixedArray::make(head.length() + s.request_body.length(), b'\x00')
    for i = 0; i < head.length(); i = i + 1 {
      buf[i] = head[i]
    }
    for i = 0; i < s.request_body.length(); i = i + 1 {
      buf[head.length() + i] = s.request_body[i]
    }
    Bytes::from_array(buf)
  }
}

///|
/// Why one probe attempt failed — drives retry classification and the
/// deadline error's last-seen detail.
priv suberror HttpProbeFailure {
  DialFailed(String)
  NonHttp(String)
  Mismatch(String)
  ConfigError(String)
}

///|
/// Read a bounded response head + body from `conn`. Anything that is
/// not a parseable HTTP/1.1 response is a NonHttp failure (TLS bytes
/// land here too). The body is truncated at HTTP_WAIT_BODY_CAP for
/// matching — never fatal.
async fn read_probe_response(
  conn : TcpReader,
) -> (Int32, Array[(String, String)], Bytes) {
  let head_str = conn.read_until("\r\n\r\n") catch {
    e => raise DialFailed("\{e}")
  }
  guard head_str is Some(head_str) else {
    raise NonHttp("connection closed before headers")
  }
  let lines = head_str.split("\r\n").collect()
  guard lines.length() > 0 else { raise NonHttp("empty response head") }
  let status_line = lines[0]
  guard status_line.has_prefix("HTTP/1.") else {
    raise NonHttp("status line not HTTP: \{status_line.to_owned()}")
  }
  // "HTTP/1.1 200 OK" → status digits
  let parts = status_line.split(" ").collect()
  guard parts.length() >= 2 else {
    raise NonHttp("malformed status line: \{status_line.to_owned()}")
  }
  let mut status : Int64 = 0
  let mut digits = 0
  for c in parts[1].iter() {
    if c is ('0'..<='9') {
      status = status * 10 + (c.to_int() - '0'.to_int()).to_int64()
      digits += 1
    }
  }
  guard digits == 3 else {
    raise NonHttp("malformed status code: \{status_line.to_owned()}")
  }
  let headers : Array[(String, String)] = []
  for line in lines[1:] {
    match line.find(":") {
      Some(i) =>
        headers.push(
          (
            ascii_lower(line[:i].to_owned()).trim().to_owned(),
            line[i + 1:].to_owned().trim().to_owned(),
          ),
        )
      None => ()
    }
  }
  // Body: Content-Length, chunked, or close-delimited — capped at the
  // body cap for matching (truncation is not an error).
  let mut body : Array[Byte] = []
  let mut is_chunked = false
  let mut content_length : Int64 = -1
  for (k, v) in headers {
    if k == "transfer-encoding" && ascii_lower(v).contains("chunked") {
      is_chunked = true
    }
    if k == "content-length" {
      let mut n : Int64 = 0
      for c in v.iter() {
        if c is ('0'..<='9') {
          n = n * 10 + (c.to_int() - '0'.to_int()).to_int64()
        }
      }
      content_length = n
    }
  }
  if is_chunked {
    body = read_chunked_body(conn)
  } else if content_length >= 0 {
    let want = if content_length > HTTP_WAIT_BODY_CAP.to_int64() {
      HTTP_WAIT_BODY_CAP
    } else {
      content_length.to_int()
    }
    if want > 0 {
      let b = conn.read_exactly(want) catch {
        _ => raise NonHttp("body truncated before Content-Length")
      }
      for i = 0; i < b.length(); i = i + 1 {
        body.push(b[i])
      }
    }
  } else {
    // no length hints: read until close, capped
    while body.length() < HTTP_WAIT_BODY_CAP {
      match (conn.read_some() catch { _ => None }) {
        Some(chunk) =>
          for c in chunk {
            if body.length() < HTTP_WAIT_BODY_CAP {
              body.push(c)
            }
          }
        None => break
      }
    }
  }
  (status.to_int(), headers, Bytes::from_array(body))
}

///|
async fn read_chunked_body(conn : TcpReader) -> Array[Byte] {
  let body : Array[Byte] = []
  for ;; {
    let line_opt = conn.read_until("\r\n") catch {
      _ => raise NonHttp("chunk size line unreadable")
    }
    guard line_opt is Some(line) else {
      raise NonHttp("stream ended before chunk size")
    }
    let mut size : Int64 = 0
    for c in line.iter() {
      if c is ('0'..<='9') {
        size = size * 16 + (c.to_int() - '0'.to_int()).to_int64()
      } else if c is ('a'..<='f') {
        size = size * 16 + (c.to_int() - 'a'.to_int() + 10).to_int64()
      } else if c is ('A'..<='F') {
        size = size * 16 + (c.to_int() - 'A'.to_int() + 10).to_int64()
      } else {
        break
      }
    }
    if size == 0 {
      break
    }
    if body.length() < HTTP_WAIT_BODY_CAP {
      let b = conn.read_exactly(size.to_int()) catch {
        _ => raise NonHttp("chunk data truncated")
      }
      for i = 0; i < b.length(); i = i + 1 {
        if body.length() < HTTP_WAIT_BODY_CAP {
          body.push(b[i])
        }
      }
    } else {
      // skip chunk bytes beyond the cap without keeping them
      ignore(conn.read_exactly(size.to_int()) catch { _ => b"" })
    }
    // trailing CRLF after each chunk
    ignore(conn.read_exactly(2) catch { _ => b"" })
  }
  body
}

///|
/// Match a received response against the strategy's expected
/// conditions. Header names compare case-insensitively.
fn strategy_matches(
  s : HttpWaitStrategy,
  status : Int32,
  headers : Array[(String, String)],
  body : Bytes,
) -> String? {
  match s.expected_status {
    Some(want) =>
      if status != want {
        return Some("status \{status} != \{want}")
      }
    None => ()
  }
  for (want_k, want_v) in s.expected_headers {
    let mut found = false
    for (k, v) in headers {
      if k == ascii_lower(want_k) && v == want_v {
        found = true
        break
      }
    }
    if !found {
      return Some("header \{want_k}: \{want_v} not present")
    }
  }
  match s.expected_body {
    Some(want) =>
      if !@utf8.decode_lossy(body[:]).contains(want) {
        return Some("body does not contain '\{want}'")
      }
    None => ()
  }
  None
}

///|
/// Tiny reader adapter over a connected Tcp for the probe path.
priv struct TcpReader {
  conn : @socket.Tcp
}

///|
async fn TcpReader::read_until(self : TcpReader, delim : String) -> String? {
  self.conn.read_until(delim)
}

///|
async fn TcpReader::read_exactly(self : TcpReader, n : Int32) -> Bytes {
  self.conn.read_exactly(n)
}

///|
async fn TcpReader::read_some(self : TcpReader) -> Bytes? {
  self.conn.read_some()
}

///|
/// Resolve the host port to dial: the strategy's container port when
/// set, else the first published mapping; IPv4 then IPv6 fallback
/// (upstream rule).
async fn Container::resolve_http_port(
  self : Container,
  strategy : HttpWaitStrategy,
) -> (String, Int32) raise HttpProbeFailure {
  let candidates : Array[ContainerPort] = match strategy.port {
    Some(p) =>
      [ContainerPort::tcp(p)] catch {
        _ => raise ConfigError("invalid container port \{p}")
      }
    None => self.mappings.map(fn(m) { m.container_port() })
  }
  guard candidates.length() > 0 else {
    raise ConfigError("no published port to connect to")
  }
  for cp in candidates {
    let v4 = Some(self.get_host_port_ipv4(cp)) catch { _ => None }
    match v4 {
      Some(hp) => return ("127.0.0.1", hp)
      None => ()
    }
    let v6 = Some(self.get_host_port_ipv6(cp)) catch { _ => None }
    match v6 {
      Some(hp) => return ("::1", hp)
      None => ()
    }
  }
  raise ConfigError("no published host port resolved")
}

///|
/// The HTTP readiness loop: probe, classify, retry at poll interval
/// until the shared deadline. Config errors fail fast without a
/// connect attempt; everything else retries until the deadline.
async fn Container::http_wait_until(
  self : Container,
  strategy : HttpWaitStrategy,
  deadline : Int64,
) -> Unit {
  guard strategy.has_matcher() else {
    fail("http wait has no matcher (expected status/header/body are all unset)")
  }
  let mut last = "no attempt yet"
  for ;; {
    // startup_remaining_ms raises once the shared deadline passes —
    // enrich the error with the last failure classification first.
    let remaining = startup_remaining_ms(deadline) catch {
      _ => {
        fail("http wait deadline exceeded (last: \{last})")
        0
      }
    }
    let attempt_budget = if strategy.request_timeout_ms < remaining {
      strategy.request_timeout_ms
    } else {
      remaining
    }
    let outcome = try {
      let (host, port) = self.resolve_http_port(strategy)
      let request = build_http_probe(strategy, host, port)
      let conn = @async.with_timeout(attempt_budget, () => {
        @socket.Tcp::connect_to_host(host[:], port~)
      }) catch {
        e => raise DialFailed("connect \{host}:\{port}: \{e}")
      }
      defer conn.close()
      (conn.write(request) catch { e => raise DialFailed("write: \{e}") })
      |> ignore
      let reader : TcpReader = { conn, }
      let (status, headers, body) = @async.with_timeout(attempt_budget, () => {
        read_probe_response(reader)
      }) catch {
        HttpProbeFailure::NonHttp(d) => raise NonHttp(d)
        HttpProbeFailure::Mismatch(d) => raise Mismatch(d)
        e => raise NonHttp("read: \{e}")
      }
      match strategy_matches(strategy, status, headers, body) {
        None => "ok"
        Some(why) => raise Mismatch(why)
      }
    } catch {
      HttpProbeFailure::ConfigError(d) => {
        fail("http wait misconfigured: \{d}")
        "unreachable"
      }
      HttpProbeFailure::DialFailed(d) => {
        last = "connect failed: \{d}"
        "retry"
      }
      HttpProbeFailure::NonHttp(d) => {
        last = "non-http response: \{d}"
        "retry"
      }
      HttpProbeFailure::Mismatch(d) => {
        last = "condition mismatch: \{d}"
        "retry"
      }
    }
    if outcome == "ok" {
      return
    }
    let left = startup_remaining_ms(deadline) catch {
      _ => fail("http wait deadline exceeded (last: \{last})")
    }
    let sleep_ms = if strategy.poll_interval_ms < left {
      strategy.poll_interval_ms
    } else {
      left
    }
    if sleep_ms > 0 {
      @async.sleep(sleep_ms)
    }
  }
}
