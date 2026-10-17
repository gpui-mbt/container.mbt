// Public failure classification (issue 0049). Additive: existing
// `raise` effects and messages are unchanged; callers that need to
// branch can use `classify_failure`.

///|
pub(all) enum ClientFailure {
  Connect
  Protocol
  Timeout
  Authentication
  ImageNotFound
  ContainerNotFound
  ContainerPathNotFound
  Configuration
  Json
  Other
}

///|
pub(all) enum FailureKind {
  Client(ClientFailure)
  WaitContainer
  PortNotExposed
  Exec
  Io
  Other
}

///|
pub fn ClientFailure::name(self : ClientFailure) -> String {
  match self {
    Connect => "connect"
    Protocol => "protocol"
    Timeout => "timeout"
    Authentication => "authentication"
    ImageNotFound => "image-not-found"
    ContainerNotFound => "container-not-found"
    ContainerPathNotFound => "container-path-not-found"
    Configuration => "configuration"
    Json => "json"
    Other => "other"
  }
}

///|
pub fn FailureKind::name(self : FailureKind) -> String {
  match self {
    Client(c) => "client/\{c.name()}"
    WaitContainer => "wait-container"
    PortNotExposed => "port-not-exposed"
    Exec => "exec"
    Io => "io"
    Other => "other"
  }
}

///|
fn message_contains_any(message : String, needles : Array[String]) -> Bool {
  let lower = message.to_lower()
  for needle in needles {
    if lower.contains(needle) {
      return true
    }
  }
  false
}

///|
fn classify_client_message(message : String) -> ClientFailure {
  if message_contains_any(message, ["unauthorized", "authentication", "401", "403", "denied"]) {
    Authentication
  } else if message_contains_any(message, ["image not found", "no such image", "manifest unknown"]) {
    ImageNotFound
  } else if message_contains_any(message, ["path not found", "could not find the file"]) {
    ContainerPathNotFound
  } else if message_contains_any(message, ["container not found", "no such container", "notfound"]) {
    ContainerNotFound
  } else if message_contains_any(message, ["timed out", "timeout", "deadline"]) {
    Timeout
  } else if message_contains_any(message, ["connect", "socket", "refused", "no such file"]) {
    Connect
  } else if message_contains_any(message, ["scp", "json", "decode", "utf-8", "malformed"]) {
    Json
  } else {
    Other
  }
}

///|
/// Map an adapter error to the public failure vocabulary. Unknown
/// errors fall back to `Other`; the original message is never hidden.
pub fn classify_failure(error : Error) -> FailureKind {
  match error {
    EngineError::ImageNotFound(..) => Client(ImageNotFound)
    EngineError::ContainerNotFound(..) => Client(ContainerNotFound)
    EngineError::ContainerPathNotFound(..) => Client(ContainerPathNotFound)
    EngineError::Unauthorized(..) | EngineError::Forbidden(..) =>
      Client(Authentication)
    EngineError::DeadlineExceeded(..) => Client(Timeout)
    EngineError::TransportError(..) => Client(Connect)
    EngineError::MalformedResponse(..) => Client(Protocol)
    EngineError::BodyTooLarge(..) => Client(Protocol)
    EngineError::ApiVersionTooOld(..) => Client(Configuration)
    XpcError::NotApple | XpcError::Connect => Client(Connect)
    XpcError::Timeout => Client(Timeout)
    XpcError::Malformed(..) | XpcError::NonUtf8 | XpcError::MissingKey(..) |
    XpcError::TypeMismatch(..) | XpcError::Closed | XpcError::Allocation =>
      Client(Protocol)
    XpcError::Remote(code~, message~) =>
      Client(classify_client_message("\{code} \{message}"))
    SocketConnectError::Timeout(_) => Client(Timeout)
    SocketConnectError::SocketMissing(_) | SocketConnectError::Refused(_) |
    SocketConnectError::PermissionDenied(_) | SocketConnectError::ConnectFailed(_) =>
      Client(Connect)
    HttpDecodeError::BodyTooLarge(_) | HttpDecodeError::Truncated(_) =>
      Client(Protocol)
    HttpDecodeError::_ => Client(Protocol)
    Failure::Failure(message) => Client(classify_client_message(message))
    _ => Other
  }
}

///|
/// Redact common secret spellings from an error/diagnostic string. The
/// registry auth header is never included by the Engine adapter, but
/// CLI stderr is opaque, so callers should run it through this helper
/// before logging.
pub fn redact_secret(text : String) -> String {
  let mut out = text
  for key in [
    "x-registry-auth:",
    "authorization:",
    "password=",
    "token=",
    "secret=",
  ] {
    let mut start = 0
    while true {
      let lower = out.to_lower()
      let index = match lower[start:].find(key) {
        Some(i) => start + i
        None => break
      }
      let value_start = index + key.length()
      let mut end = value_start
      if key == "authorization:" || key == "x-registry-auth:" {
        while end < out.length() && out[end] != '\n' && out[end] != '\r' {
          end = end + 1
        }
      } else {
        while end < out.length() && out[end] != ' ' && out[end] != '\n' &&
          out[end] != '\r' && out[end] != '"' && out[end] != ',' {
          end = end + 1
        }
      }
      out = out[:value_start].to_owned() + "[REDACTED]" + out[end:].to_owned()
      start = value_start + "[REDACTED]".length()
    }
  }
  out
}
