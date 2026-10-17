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

// M1 Docker Engine client: one request per Unix-socket connection with
// upstream conventions (`Host: localhost`, `Connection: close`, no
// write half-close), decoded by the sans-IO HTTP decoder and classified
// by `EngineError`. Daemon preflight (`/_ping` + `/version` + minimum
// API version) per issue 0008.

///|
/// Minimum Docker Engine API version this client requires.
/// Provisional: upstream has no explicit minimum; pinned once 0010+ APIs
/// are verified against a real daemon.
pub const MIN_DOCKER_API_VERSION : String = "1.24"

///|
/// A Docker Engine client over the Unix socket transport. One
/// connection per request; no CLI involved.
pub struct DockerClient {
  transport : UnixSocketTransport
}

///|
pub fn DockerClient::new(
  socket_path~ : String = DEFAULT_DOCKER_SOCKET_PATH,
  connect_timeout_ms~ : Int32 = 30_000,
) -> DockerClient {
  { transport: UnixSocketTransport::new(socket_path~, connect_timeout_ms~), }
}

///|
/// Subset of `GET /version` we act on.
pub struct DaemonVersion {
  api_version : String
  version : String
}

///|
/// Encode one Engine request following upstream conventions:
/// `Host: localhost`, `Connection: close`, Content-Length only when a
/// body exists.
fn encode_engine_request(
  verb~ : String,
  path~ : String,
  headers~ : Array[(String, String)] = [],
  body~ : Bytes = b"",
) -> Bytes {
  let buf = StringBuilder()
  buf.write_string("\{verb} \{path} HTTP/1.1\r\nHost: localhost\r\n")
  for pair in headers {
    buf.write_string("\{pair.0}: \{pair.1}\r\n")
  }
  if body.length() > 0 {
    buf.write_string("Content-Length: \{body.length()}\r\n")
  }
  buf.write_string("Connection: close\r\n\r\n")
  let head = @utf8.encode(buf.to_string())
  let out : Array[Byte] = []
  for b in head {
    out.push(b)
  }
  for b in body {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// Send one request and return the decoded response. Any non-2xx status
/// is classified into `EngineError` via `classify_engine_error`;
/// transport/decode failures map via `engine_error_of_failure`.
/// `deadline` bounds connect/write/read on the shared clock — no phase
/// restarts a timer (issue 0018).
pub async fn DockerClient::request(
  self : DockerClient,
  verb~ : String,
  path~ : String,
  op~ : String,
  context~ : EngineOp = EngineOp::container_lifecycle(),
  target~ : String = "",
  headers~ : Array[(String, String)] = [],
  body~ : Bytes = b"",
  deadline? : Deadline,
) -> HttpResponse {
  let transport = match deadline {
    None => self.transport
    Some(d) => {
      if d.expired() {
        raise EngineError::DeadlineExceeded(op~)
      }
      { ..self.transport, connect_timeout_ms: d.remaining_ms().to_int(), }
    }
  }
  let conn = try transport.connect() catch {
    err => raise engine_error_of_failure(op~, err)
  } noraise {
    c => c
  }
  defer conn.close()
  let dec = HttpResponseDecoder::new()
  try {
    match deadline {
      None =>
        conn.write_all(encode_engine_request(verb~, path~, headers~, body~))
      Some(d) =>
        d.run(op~, () => {
          conn.write_all(encode_engine_request(verb~, path~, headers~, body~))
        })
    }
    for ;; {
      if dec.is_complete() {
        break
      }
      match deadline {
        None =>
          match conn.read_some() {
            Some(chunk) => dec.feed(chunk)
            None => {
              dec.eof()
              break
            }
          }
        Some(d) => {
          let chunk : Bytes? = d.run(op~, () => conn.read_some())
          match chunk {
            Some(c) => dec.feed(c)
            None => {
              dec.eof()
              break
            }
          }
        }
      }
    }
  } catch {
    err =>
      match err {
        EngineError::DeadlineExceeded(_) => raise err
        _ => raise engine_error_of_failure(op~, err)
      }
  } noraise {
    _ => ()
  }
  let resp = dec.response()
  if resp.status < 200 || resp.status >= 300 {
    raise classify_engine_error(
      op~,
      context~,
      status=resp.status,
      body=resp.body,
      target~,
    )
  }
  resp
}

///|
/// `GET /_ping` — pure connectivity check. Any failure is a daemon or
/// transport problem, never silently retried by the CLI path.
pub async fn DockerClient::ping(
  self : DockerClient,
  deadline? : Deadline,
) -> Unit {
  ignore(
    self.request(
      verb="GET",
      path="/_ping",
      op="ping",
      context=EngineOp::container_lifecycle(),
      deadline?,
    ),
  )
}

///|
/// `GET /version` — fetch daemon version info.
pub async fn DockerClient::version(
  self : DockerClient,
  deadline? : Deadline,
) -> DaemonVersion {
  let resp = self.request(
    verb="GET",
    path="/version",
    op="version",
    context=EngineOp::container_lifecycle(),
    deadline?,
  )
  let json = try @json.parse(@utf8.decode_lossy(resp.body)) catch {
    _ =>
      raise EngineError::MalformedResponse(
        op="version",
        detail="response body is not JSON",
      )
  } noraise {
    j => j
  }
  match json {
    Object(m) => {
      let api = match m.get("ApiVersion") {
        Some(String(s)) => s
        _ =>
          raise EngineError::MalformedResponse(
            op="version",
            detail="missing ApiVersion field",
          )
      }
      let version = match m.get("Version") {
        Some(String(s)) => s
        _ => ""
      }
      { api_version: api, version, }
    }
    _ =>
      raise EngineError::MalformedResponse(
        op="version",
        detail="response is not a JSON object",
      )
  }
}

///|
/// `GET /_ping` then `GET /version`; fails before any side-effecting
/// call when the daemon is unreachable, not a Docker Engine, or too old.
pub async fn DockerClient::preflight(
  self : DockerClient,
  min_api~ : String = MIN_DOCKER_API_VERSION,
  deadline? : Deadline,
) -> DaemonVersion {
  self.ping(deadline?)
  let v = self.version(deadline?)
  if !api_version_at_least(v.api_version, min_api) {
    raise EngineError::ApiVersionTooOld(
      op="preflight",
      found=v.api_version,
      required=min_api,
    )
  }
  v
}

///|
/// Lexicographic numeric compare on "major.minor" API versions.
fn api_version_at_least(found : String, required : String) -> Bool {
  let parse = fn(v : String) -> (Int32, Int32)? {
    match v.split(".").collect() {
      [maj, min] => {
        let mut ok = true
        for c in maj.iter().concat(min.iter()) {
          if !(c is ('0'..<='9')) {
            ok = false
          }
        }
        if !ok {
          return None
        }
        let to_i = fn(s : StringView) -> Int32 {
          let mut n = 0
          for c in s {
            n = n * 10 + (c.to_int() - '0'.to_int())
          }
          n
        }
        Some((to_i(maj), to_i(min)))
      }
      _ => None
    }
  }
  match (parse(found), parse(required)) {
    (Some((fmaj, fmin)), Some((rmaj, rmin))) =>
      fmaj > rmaj || (fmaj == rmaj && fmin >= rmin)
    _ => false
  }
}
