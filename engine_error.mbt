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

// M1 engine error classification (issue 0017). Same-status responses
// mean different things depending on the operation context, so the
// caller supplies an `EngineOp` alongside status + bounded body.
// Deterministic and table-driven so fixtures can compare results.
// Internal for now; the public error shape is decided in 0049.

///|
/// Which Engine operation produced the response — decides how a 404
/// (and friends) is classified.
pub enum EngineOp {
  /// image resolve/pull: 404 means the image descriptor was not found.
  ResolveImage
  /// inspect/stop/rm/wait/exec/logs: 404 means the container is gone.
  ContainerLifecycle
  /// copy/archive: 404 with the "Could not find the file " prefix means
  /// the in-container path is missing (upstream classify_archive_404).
  Archive
}

///|
/// Operation contexts as named constructors.
pub fn EngineOp::resolve_image() -> EngineOp {
  ResolveImage
}

///|
pub fn EngineOp::container_lifecycle() -> EngineOp {
  ContainerLifecycle
}

///|
pub fn EngineOp::archive() -> EngineOp {
  Archive
}

///|
/// Classification of a failed Engine API call. Payloads always carry the
/// operation name; `message` is the daemon's `{"message": ...}` when
/// present, never request headers or credentials.
pub(all) suberror EngineError {
  ImageNotFound(op~ : String, image~ : String)
  ContainerNotFound(op~ : String, container~ : String)
  ContainerPathNotFound(op~ : String, container~ : String, path~ : String)
  BadRequest(op~ : String, message~ : String)
  Unauthorized(op~ : String, message~ : String)
  Forbidden(op~ : String, message~ : String)
  Conflict(op~ : String, message~ : String)
  ServerError(op~ : String, status~ : Int32, message~ : String)
  /// A status we do not specifically classify (unexpected 3xx/4xx).
  UnexpectedStatus(op~ : String, status~ : Int32, message~ : String)
  /// Response bytes were not decodable / malformed.
  MalformedResponse(op~ : String, detail~ : String)
  /// Error body exceeded the limit — truncated bodies are never used
  /// for classification.
  BodyTooLarge(op~ : String, limit~ : Int32)
  /// Socket/connect/EOF-level failure (not an HTTP status at all).
  TransportError(op~ : String, detail~ : String)
  /// The daemon responded but its API version is below the minimum.
  ApiVersionTooOld(op~ : String, found~ : String, required~ : String)
  /// The shared operation deadline expired mid-operation. Distinct
  /// from `TransportError` (connection broke) per issue 0018.
  DeadlineExceeded(op~ : String)
}

///|
/// Exposes `Show`'s methods as regular methods (compiler-recommended form).
pub extend EngineError with Show::{to_string, output}

///|
pub impl Show for EngineError with fn output(self, logger) {
  logger.write_string(self.describe())
}

///|
/// Deterministic single-line description — fixture-comparable.
pub fn EngineError::describe(self : EngineError) -> String {
  match self {
    ImageNotFound(op~, image~) => "\{op}: image not found: \{image}"
    ContainerNotFound(op~, container~) =>
      "\{op}: container not found: \{container}"
    ContainerPathNotFound(op~, container~, path~) =>
      "\{op}: path not found in container \{container}: \{path}"
    BadRequest(op~, message~) => "\{op}: bad request: \{message}"
    Unauthorized(op~, message~) => "\{op}: unauthorized: \{message}"
    Forbidden(op~, message~) => "\{op}: forbidden: \{message}"
    Conflict(op~, message~) => "\{op}: conflict: \{message}"
    ServerError(op~, status~, message~) =>
      "\{op}: daemon error (\{status}): \{message}"
    UnexpectedStatus(op~, status~, message~) =>
      "\{op}: unexpected status \{status}: \{message}"
    MalformedResponse(op~, detail~) => "\{op}: malformed response: \{detail}"
    BodyTooLarge(op~, limit~) =>
      "\{op}: error response body exceeds \{limit} bytes limit"
    TransportError(op~, detail~) => "\{op}: transport error: \{detail}"
    ApiVersionTooOld(op~, found~, required~) =>
      "\{op}: Docker API version \{found} is older than required \{required}"
    DeadlineExceeded(op~) => "\{op}: deadline exceeded"
  }
}

///|
const ARCHIVE_404_PREFIX : String = "Could not find the file "

///|
/// Extract `{"message": "..."}` from a daemon error body. Non-JSON,
/// missing key, or non-string value all yield None — the caller then
/// classifies on status alone (fail closed).
fn json_message(body : Bytes) -> String? {
  let json = try @json.parse(@utf8.decode_lossy(body)) catch {
    _ => return None
  } noraise {
    j => j
  }
  match json {
    Object(m) =>
      match m.get("message") {
        Some(String(s)) => Some(s)
        _ => None
      }
    _ => None
  }
}

///|
/// Classify a non-2xx Engine API response. `body` must already be the
/// fully-read, bounded error body — never a truncated one.
pub fn classify_engine_error(
  op~ : String,
  context~ : EngineOp,
  status~ : Int32,
  body~ : Bytes,
  target~ : String = "",
  path~ : String = "",
) -> EngineError {
  let message = json_message(body).unwrap_or("")
  match status {
    400 => BadRequest(op~, message~)
    401 => Unauthorized(op~, message~)
    403 => Forbidden(op~, message~)
    404 =>
      match context {
        ResolveImage => ImageNotFound(op~, image=target)
        Archive =>
          match json_message(body) {
            Some(m) if m.has_prefix(ARCHIVE_404_PREFIX) =>
              ContainerPathNotFound(op~, container=target, path~)
            _ => ContainerNotFound(op~, container=target)
          }
        ContainerLifecycle => ContainerNotFound(op~, container=target)
      }
    409 => Conflict(op~, message~)
    s if s >= 500 => ServerError(op~, status=s, message~)
    s => UnexpectedStatus(op~, status=s, message~)
  }
}

///|
/// Map a decode/transport-layer failure onto the classification table
/// so error paths can share one error type.
pub fn engine_error_of_failure(op~ : String, err : Error) -> EngineError {
  match err {
    HttpDecodeError::BodyTooLarge(limit) => BodyTooLarge(op~, limit~)
    HttpDecodeError::Truncated(_) | SocketConnectError::_ =>
      TransportError(op~, detail=err.to_string())
    HttpDecodeError::_ => MalformedResponse(op~, detail=err.to_string())
    _ => TransportError(op~, detail=err.to_string())
  }
}
