// Apple Container XPC bridge: typed request/reply wrapper over the C
// shim. XPC sends are non-blocking; MoonBit polls with its async
// scheduler so a long `containerWait` cannot freeze unrelated tasks.
//
// Ownership: every handle is an opaque C pointer. `XpcConnection`,
// `XpcMessage` and `XpcReply` must be closed explicitly; `send` does so
// with `defer`. A pending context is abandoned on every error path and
// the C reply handler releases a late reply.

///|
pub(all) suberror XpcError {
  /// XPC is only available on macOS natives.
  NotApple
  /// `xpc_connection_create_mach_service` returned no connection.
  Connect
  /// The reply did not arrive before the caller's deadline.
  Timeout
  /// The context was abandoned or already consumed.
  Closed
  /// The remote returned an XPC error object or a JSON error payload.
  Remote(code~ : String, message~ : String)
  /// An error payload was not UTF-8 / not valid JSON.
  Malformed(detail~ : String)
  /// A reply string/data payload was not valid UTF-8.
  NonUtf8
  /// A required reply key is absent.
  MissingKey(key~ : String)
  /// A reply key exists with an unexpected XPC type.
  TypeMismatch(key~ : String, expected~ : String)
  /// The C bridge could not allocate a context/message.
  Allocation
}

///|
pub fn XpcError::describe(self : XpcError) -> String {
  match self {
    NotApple => "Apple Container XPC is only available on macOS"
    Connect => "failed to connect to the Apple Container XPC service"
    Timeout => "XPC request timed out"
    Closed => "XPC request context was abandoned"
    Remote(code~, message~) => "XPC error \{code}: \{message}"
    Malformed(detail~) => "XPC error unparseable (\{detail})"
    NonUtf8 => "XPC error unparseable (response is not UTF-8)"
    MissingKey(key~) => "XPC reply is missing key: \{key}"
    TypeMismatch(key~, expected~) =>
      "XPC reply key \{key} is not \{expected}"
    Allocation => "failed to allocate an XPC request context"
  }
}

///|
pub extend XpcError with Show::{to_string, output}

///|
pub impl Show for XpcError with fn output(self, logger) {
  logger.write_string(self.describe())
}

///|
pub const XPC_SERVICE : String = "com.apple.container.apiserver"

///|
pub const XPC_IMAGE_SERVICE : String = "com.apple.container.core.container-core-images"

///|
pub const XPC_ROUTE_KEY : String = "com.apple.container.xpc.route"

///|
pub const XPC_ERROR_KEY : String = "com.apple.container.xpc.error"

///|
/// Default one-shot XPC timeout (upstream `DEFAULT_TIMEOUT`).
pub const XPC_DEFAULT_TIMEOUT_MS : Int = 60000

///|
/// `containerWait`-style long timeout (upstream `LONG_TIMEOUT`).
pub const XPC_LONG_TIMEOUT_MS : Int = 86400000

///|
/// One typed value in an XPC request dictionary.
pub(all) enum XpcValue {
  Str(String)
  Data(Bytes)
  Bool(Bool)
  Int64(Int64)
  UInt64(UInt64)
  Fd(Int32)
}

///|
fn c_string(value : String) -> Bytes raise {
  guard !value.contains_char('\u{0}') else {
    raise XpcError::Malformed(detail="string contains NUL")
  }
  @utf8.encode(value)
}

///|
fn decode_utf8(bytes : Bytes) -> String raise {
  try @utf8.decode(bytes) catch {
    _ => raise XpcError::NonUtf8
  } noraise {
    text => text
  }
}

///|
pub fn is_apple() -> Bool {
  container_is_apple() != 0
}

///|
pub fn count_open_fds() -> Int {
  container_count_open_fds()
}

///|
/// Create an OS pipe pair as `(read, write)`. Caller owns both FDs.
pub fn pipe_pair() -> (Int32, Int32) raise {
  let packed = container_pipe_pair()
  if packed < 0 {
    raise XpcError::Malformed(detail="pipe(2) failed")
  }
  ((packed >> 32).to_int(), packed.to_int())
}

///|
pub struct XpcConnection {
  priv raw : XpcConnectionPtr
}

///|
pub fn XpcConnection::connect(service : String) -> XpcConnection raise {
  guard is_apple() else { raise XpcError::NotApple }
  let raw = xpc_connect(c_string(service))
  if xpc_is_null(raw) != 0 {
    raise XpcError::Connect
  }
  { raw, }
}

///|
pub fn XpcConnection::close(self : XpcConnection) -> Unit {
  xpc_connection_cancel(self.raw)
  xpc_connection_release(self.raw)
}

///|
pub struct XpcMessage {
  priv raw : XpcMessagePtr
}

///|
pub fn XpcMessage::new() -> XpcMessage raise {
  guard is_apple() else { raise XpcError::NotApple }
  let raw = xpc_message_create()
  if xpc_message_is_null(raw) != 0 {
    raise XpcError::Allocation
  }
  { raw, }
}

///|
pub fn XpcMessage::close(self : XpcMessage) -> Unit {
  xpc_message_release(self.raw)
}

///|
pub fn XpcMessage::set(self : XpcMessage, key : String, value : XpcValue) -> Unit raise {
  let key = c_string(key)
  match value {
    Str(s) => xpc_set_string(self.raw, key, c_string(s))
    Data(d) => xpc_set_data(self.raw, key, d, d.length())
    Bool(b) => xpc_set_bool(self.raw, key, b)
    Int64(v) => xpc_set_int64(self.raw, key, v)
    UInt64(v) => xpc_set_uint64(self.raw, key, v)
    Fd(fd) =>
      if xpc_set_fd(self.raw, key, fd) == 0 {
        raise XpcError::Malformed(detail="failed to attach a file descriptor to the XPC message")
      }
  }
}

///|
pub struct XpcReply {
  priv raw : XpcReplyPtr
}

///|
pub fn XpcReply::close(self : XpcReply) -> Unit {
  xpc_reply_release(self.raw)
}

///|
fn XpcReply::type_of(self : XpcReply, key : String) -> Int32 raise {
  xpc_type_of(self.raw, c_string(key))
}

///|
fn type_name(code : Int32) -> String {
  match code {
    0 => "missing"
    1 => "string"
    2 => "data"
    3 => "int64"
    4 => "uint64"
    5 => "bool"
    6 => "array"
    7 => "dictionary"
    _ => "other"
  }
}

///|
fn XpcReply::ensure_type(self : XpcReply, key : String, expected : Int32) -> Int32 raise {
  let found = self.type_of(key)
  if found == 0 {
    raise XpcError::MissingKey(key~)
  }
  if found != expected {
    raise XpcError::TypeMismatch(key~, expected=type_name(expected))
  }
  found
}

///|
pub fn XpcReply::string_opt(self : XpcReply, key : String) -> String? raise {
  if self.type_of(key) == 0 {
    return None
  }
  ignore(self.ensure_type(key, 1))
  Some(decode_utf8(xpc_copy_string(self.raw, c_string(key))))
}

///|
pub fn XpcReply::string(self : XpcReply, key : String) -> String raise {
  match self.string_opt(key) {
    Some(value) => value
    None => raise XpcError::MissingKey(key~)
  }
}

///|
pub fn XpcReply::data_opt(self : XpcReply, key : String) -> Bytes? raise {
  if self.type_of(key) == 0 {
    return None
  }
  ignore(self.ensure_type(key, 2))
  Some(xpc_copy_data(self.raw, c_string(key)))
}

///|
pub fn XpcReply::data(self : XpcReply, key : String) -> Bytes raise {
  match self.data_opt(key) {
    Some(value) => value
    None => raise XpcError::MissingKey(key~)
  }
}

///|
pub fn XpcReply::int64(self : XpcReply, key : String) -> Int64 raise {
  ignore(self.ensure_type(key, 3))
  let out : Ref[Int64] = { val: 0L, }
  if xpc_get_int64(self.raw, c_string(key), out) == 0 {
    raise XpcError::TypeMismatch(key~, expected="int64")
  }
  out.val
}

///|
pub fn XpcReply::uint64(self : XpcReply, key : String) -> UInt64 raise {
  ignore(self.ensure_type(key, 4))
  let out : Ref[UInt64] = { val: 0UL, }
  if xpc_get_uint64(self.raw, c_string(key), out) == 0 {
    raise XpcError::TypeMismatch(key~, expected="uint64")
  }
  out.val
}

///|
pub fn XpcReply::bool(self : XpcReply, key : String) -> Bool raise {
  ignore(self.ensure_type(key, 5))
  let out : Ref[Int32] = { val: 0, }
  if xpc_get_bool(self.raw, c_string(key), out) == 0 {
    raise XpcError::TypeMismatch(key~, expected="bool")
  }
  out.val != 0
}

///|
pub fn XpcReply::is_error(self : XpcReply) -> Bool {
  xpc_is_error(self.raw) != 0
}

///|
pub fn XpcReply::error_description(self : XpcReply) -> String {
  @utf8.decode_lossy(xpc_error_description(self.raw))
}

///|
/// Copy the two log FDs. The caller owns both descriptors.
pub fn XpcReply::log_fds(self : XpcReply) -> (Int32, Int32) raise {
  let fd0 : Ref[Int32] = { val: -1, }
  let fd1 : Ref[Int32] = { val: -1, }
  let count = xpc_get_log_fds(self.raw, fd0, fd1)
  if count < 2 || fd0.val < 0 || fd1.val < 0 {
    if fd0.val >= 0 {
      let _ = moonbit_close_fd(fd0.val)
    }
    if fd1.val >= 0 {
      let _ = moonbit_close_fd(fd1.val)
    }
    raise XpcError::TypeMismatch(key="logs", expected="two valid fds")
  }
  (fd0.val, fd1.val)
}

///|
extern "C" fn moonbit_close_fd(fd : Int32) -> Int32 = "moonbit_container_unix_close"

///|
fn parse_error_payload(data : Bytes) -> XpcError {
  let text = try @utf8.decode(data) catch {
    _ => return XpcError::Malformed(detail="response is not UTF-8")
  } noraise {
    text => text
  }
  let json = try @json.parse(text) catch {
    _ => return XpcError::Malformed(detail="response is not valid JSON")
  } noraise {
    json => json
  }
  let (code, message) = match json {
    Object(map) =>
      (
        match map.get("code") {
          Some(String(s)) => s
          _ => ""
        },
        match map.get("message") {
          Some(String(s)) => s
          _ => ""
        },
      )
    _ => ("", "")
  }
  XpcError::Remote(code~, message~)
}

///|
/// Send one request and wait for its reply without blocking the async
/// scheduler. The connection/message/context are released on every
/// path, including timeout and remote errors.
pub async fn send(
  service~ : String,
  route~ : String,
  entries~ : Array[(String, XpcValue)] = [],
  timeout_ms~ : Int = XPC_DEFAULT_TIMEOUT_MS,
) -> XpcReply raise {
  guard is_apple() else { raise XpcError::NotApple }
  guard timeout_ms > 0 else {
    raise XpcError::Malformed(detail="timeout must be positive")
  }
  let conn = XpcConnection::connect(service)
  defer conn.close()
  let msg = XpcMessage::new()
  defer msg.close()
  msg.set(XPC_ROUTE_KEY, Str(route))
  for (key, value) in entries {
    msg.set(key, value)
  }
  let ctx = xpc_send_async(conn.raw, msg.raw)
  if xpc_context_is_null(ctx) != 0 {
    raise XpcError::Allocation
  }
  let deadline = @async.now() + timeout_ms.to_int64()
  let mut finished = false
  defer {
    if !finished {
      xpc_abandon(ctx)
    }
  }
  while true {
    let state = xpc_poll(ctx)
    if state == 1 {
      let raw = xpc_take_reply(ctx)
      finished = true
      if xpc_reply_is_null(raw) != 0 {
        raise XpcError::Closed
      }
      let reply : XpcReply = { raw, }
      if reply.is_error() {
        let desc = reply.error_description()
        reply.close()
        raise XpcError::Remote(code="xpc", message=desc)
      }
      if reply.type_of(XPC_ERROR_KEY) == 2 {
        let payload = reply.data(XPC_ERROR_KEY)
        let err = parse_error_payload(payload)
        reply.close()
        raise err
      }
      return reply
    }
    if state == 2 {
      finished = true
      raise XpcError::Closed
    }
    if @async.now() >= deadline {
      finished = true
      xpc_abandon(ctx)
      raise XpcError::Timeout
    }
    @async.sleep(1)
  } nobreak {
    raise XpcError::Closed
  }
}

///|
/// Set O_NONBLOCK on an existing descriptor (used by the XPC log
/// reader). Returns silently; the read loop treats a failure as no data.
pub fn set_nonblock(fd : Int32) -> Unit {
  let _ = container_set_nonblock(fd)
}
