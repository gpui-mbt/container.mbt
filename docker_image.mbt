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

// M1 image pull (issue 0009). Ports upstream `split_pull_reference`,
// `resolve_image_descriptor`, `pull_image`, `check_pull_stream_errors`
// and the `resolve_or_pull` policy: pull only after `ImageNotFound`,
// exactly once, then re-resolve.
//
// Pull policy: `resolve_or_pull_image` resolves first; a local hit never
// issues `POST /images/create`. `POST /images/create` runs only on 404,
// once, and the image is resolved again afterwards. Registry auth
// (`X-Registry-Auth`) is intentionally not sent yet — 0016 adds it; that
// issue must keep header values out of logs and error text.

///|
/// Default bound for `pull_image` / `resolve_or_pull_image` when the
/// caller supplies no shared deadline. One constant per issue 0009;
/// integrated with the 0018 `Deadline` clock.
pub const DOCKER_PULL_TIMEOUT_MS : Int32 = 300_000

///|
/// `chars[a..<b]` as a String.
fn chars_slice(chars : Array[Char], a : Int32, b : Int32) -> String {
  let buf = StringBuilder()
  for i = a; i < b; i = i + 1 {
    buf.write_char(chars[i])
  }
  buf.to_string()
}

///|
/// Split the last path element of `descriptor` at its first `:` —
/// upstream `split_name_and_tag`. No `:` or an empty tag yields
/// `latest`; `:` before the last `/` is a registry port, not a tag.
fn split_name_and_tag(descriptor : String) -> (String, String) {
  let chars = descriptor.to_array()
  let mut last_slash = -1
  for i = 0; i < chars.length(); i = i + 1 {
    if chars[i] == '/' {
      last_slash = i
    }
  }
  let tag_start = last_slash + 1
  for i = tag_start; i < chars.length(); i = i + 1 {
    if chars[i] == ':' {
      let from_image = chars_slice(chars, 0, i)
      let tag = chars_slice(chars, i + 1, chars.length())
      return (from_image, if tag == "" { "latest" } else { tag })
    }
  }
  (descriptor, "latest")
}

///|
/// Port of upstream `split_pull_reference`: `@digest` wins over any
/// tag, `:` only counts after the last `/`, empty tag/digest becomes
/// `latest`. Returns `(fromImage, tag)`.
fn split_pull_reference(descriptor : String) -> (String, String) {
  let chars = descriptor.to_array()
  for i = 0; i < chars.length(); i = i + 1 {
    if chars[i] == '@' {
      let left = chars_slice(chars, 0, i)
      let digest = chars_slice(chars, i + 1, chars.length())
      let (from_image, _) = split_name_and_tag(left)
      return (from_image, if digest == "" { "latest" } else { digest })
    }
  }
  split_name_and_tag(descriptor)
}

///|
/// Port of upstream `check_pull_stream_errors`: each non-empty JSON
/// Lines entry must be an object; a non-empty `error` or
/// `errorDetail.message` fails the pull. Progress/status/`aux` fields
/// are ignored. Invalid UTF-8, non-object, or bad JSON is a
/// `MalformedResponse`.
fn check_pull_stream_errors(body : Bytes, op~ : String) -> Unit raise {
  let text = try @utf8.decode(body[:]) catch {
    _ =>
      raise EngineError::MalformedResponse(
        op~,
        detail="pull stream is not valid UTF-8",
      )
  } noraise {
    t => t
  }
  for raw_line in text.split("\n") {
    let line = raw_line.trim().to_owned()
    if line == "" {
      continue
    }
    let json = try @json.parse(line) catch {
      _ =>
        raise EngineError::MalformedResponse(
          op~,
          detail="pull stream line is not JSON: \{line}",
        )
    } noraise {
      j => j
    }
    match json {
      Object(m) => {
        let error_msg = match m.get("error") {
          Some(String(s)) if s != "" => Some(s)
          _ => None
        }
        let detail_msg = match m.get("errorDetail") {
          Some(Object(d)) =>
            match d.get("message") {
              Some(String(s)) if s != "" => Some(s)
              _ => None
            }
          _ => None
        }
        match error_msg {
          Some(msg) => raise EngineError::PullFailed(op~, message=msg)
          None =>
            if detail_msg is Some(msg) {
              raise EngineError::PullFailed(op~, message=msg)
            }
        }
      }
      _ =>
        raise EngineError::MalformedResponse(
          op~,
          detail="expected object in pull stream, got \{line}",
        )
    }
  }
}

///|
/// `GET /images/{name}/json` — resolve without pulling. 404 is
/// classified `ImageNotFound` (context `ResolveImage`), other non-2xx
/// statuses follow the 0017 table. Returns the descriptor on success.
pub async fn DockerClient::resolve_image(
  self : DockerClient,
  descriptor : String,
  deadline? : Deadline,
) -> String {
  ignore(
    self.request(
      verb="GET",
      path="/images/\{percent_encode(descriptor)}/json",
      op="resolve image",
      context=EngineOp::resolve_image(),
      target=descriptor,
      deadline?,
    ),
  )
  descriptor
}

///|
/// `POST /images/create?fromImage=..&tag=..[&platform=..]` then scan
/// the JSON Lines stream for daemon-reported failures. Non-2xx statuses
/// are classified by `request` (401 → `Unauthorized`, 404 →
/// `ImageNotFound`, etc. — distinct per issue 0009). No auth headers
/// are sent (0016); stream errors raise `PullFailed`.
pub async fn DockerClient::pull_image(
  self : DockerClient,
  descriptor : String,
  platform? : String,
  deadline? : Deadline,
) -> Unit {
  let (from_image, tag) = split_pull_reference(descriptor)
  let mut path = "/images/create?fromImage=\{percent_encode(from_image)}&tag=\{percent_encode(tag)}"
  if platform is Some(p) {
    path = "\{path}&platform=\{percent_encode(p)}"
  }
  let dl = deadline.unwrap_or(Deadline::after(DOCKER_PULL_TIMEOUT_MS))
  let resp = self.request(
    verb="POST",
    path~,
    op="pull image",
    context=EngineOp::resolve_image(),
    target=descriptor,
    deadline=dl,
  )
  check_pull_stream_errors(resp.body, op="pull image")
}

///|
/// Upstream `resolve_or_pull_linux` policy: resolve first, and only on
/// `ImageNotFound` pull once then re-resolve. Any other error
/// propagates without pulling. Without a caller deadline the whole
/// sequence is bounded by `DOCKER_PULL_TIMEOUT_MS`.
pub async fn DockerClient::resolve_or_pull_image(
  self : DockerClient,
  descriptor : String,
  platform? : String,
  deadline? : Deadline,
) -> String {
  let dl = deadline.unwrap_or(Deadline::after(DOCKER_PULL_TIMEOUT_MS))
  try self.resolve_image(descriptor, deadline=dl) catch {
    EngineError::ImageNotFound(..) => {
      self.pull_image(descriptor, platform?, deadline=dl)
      self.resolve_image(descriptor, deadline=dl)
    }
    err => raise err
  } noraise {
    d => d
  }
}
