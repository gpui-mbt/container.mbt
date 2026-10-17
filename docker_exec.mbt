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

// M1 exec attach (issue 0012). Ports upstream `exec`,
// `demux_exec_stream`, `parse_exec_inspect_state` and the
// `EXEC_EXIT_CODE_BACKOFF_MILLIS` retry: create → start → accumulate
// the multiplexed stream (64 MiB bound shared with pull/create) →
// demux → inspect until `Running == false`. Unlike upstream we raise
// `ExecExitUndetermined` instead of returning a `None` exit code.

///|
/// exec result: settled exit code plus demuxed output.
pub struct DockerExecResult {
  exit_code : Int32
  stdout : Bytes
  stderr : Bytes
}

///|
/// Port of upstream `demux_exec_stream`: 8-byte header
/// (`stream_type` 1B + reserved 3B + big-endian payload length 4B);
/// type 1 → stdout, 2 → stderr, 0/unknown dropped. A truncated final
/// payload keeps its received bytes, matching upstream tolerance.
fn demux_exec_stream(data : Bytes) -> (Bytes, Bytes) {
  let stdout : Array[Byte] = []
  let stderr : Array[Byte] = []
  let mut pos = 0
  while pos + 8 <= data.length() {
    let stream_type = data[pos].to_int()
    // u32 length as Int64 — a garbage frame can exceed Int32.
    let len64 = (data[pos + 4].to_int().to_int64() << 24) |
      (data[pos + 5].to_int().to_int64() << 16) |
      (data[pos + 6].to_int().to_int64() << 8) |
      data[pos + 7].to_int().to_int64()
    pos = pos + 8
    let end64 = pos.to_int64() + len64
    let end = if end64 < data.length().to_int64() {
      end64.to_int()
    } else {
      data.length()
    }
    let sink = if stream_type == 1 {
      stdout
    } else if stream_type == 2 {
      stderr
    } else {
      []
    }
    for i = pos; i < end; i = i + 1 {
      sink.push(data[i])
    }
    pos = end
  }
  (Bytes::from_array(stdout), Bytes::from_array(stderr))
}

///|
/// `GET /exec/{id}/json` — upstream `parse_exec_inspect_state`:
/// a missing/unparseable `Running` is treated as finished (`false`),
/// `ExitCode` is meaningful only when not running. A body that is not
/// an object at all is `MalformedResponse` (daemon anomaly).
fn parse_exec_inspect_state(body : Bytes, op~ : String) -> (Bool, Int32?) raise {
  let json = try @json.parse(@utf8.decode_lossy(body)) catch {
    _ =>
      raise EngineError::MalformedResponse(
        op~,
        detail="exec inspect body is not JSON",
      )
  } noraise {
    j => j
  }
  match json {
    Object(m) => {
      let running = match m.get("Running") {
        Some(True) => true
        _ => false
      }
      let exit_code = match m.get("ExitCode") {
        Some(Number(n, ..)) => Some(n.to_int())
        _ => None
      }
      (running, exit_code)
    }
    _ =>
      raise EngineError::MalformedResponse(
        op~,
        detail="exec inspect body is not a JSON object",
      )
  }
}

///|
/// Merge exec `overrides` onto the container's `Config.Env`: each
/// `K=V` overrides any same-key base entry and appends otherwise
/// (Docker's `Env` replaces the whole container env for the exec —
/// upstream requires the caller to pass a merged list).
fn merge_exec_env(
  base : Array[String],
  overrides : Array[(String, String)],
) -> Array[String] {
  let merged = base.copy()
  for (k, v) in overrides {
    let prefix = "\{k}="
    let kept : Array[String] = []
    for entry in merged {
      if !entry.has_prefix(prefix) {
        kept.push(entry)
      }
    }
    merged.clear()
    for entry in kept {
      merged.push(entry)
    }
    merged.push("\{k}=\{v}")
  }
  merged
}

///|
/// `POST /containers/{id}/exec` — `AttachStdout`/`AttachStderr` are
/// always true; `Env` is sent only when non-empty (empty means Docker
/// inherits the container env). Response `Id` is required.
async fn DockerClient::exec_create(
  self : DockerClient,
  id : String,
  cmd : Array[String],
  env : Array[String],
  deadline? : Deadline,
) -> String {
  let buf = StringBuilder()
  buf.write_string("{\"AttachStdout\":true,\"AttachStderr\":true,\"Cmd\":")
  buf.write_string(json_array(cmd))
  if env.length() > 0 {
    buf.write_string(",\"Env\":")
    buf.write_string(json_array(env))
  }
  buf.write_char('}')
  let resp = self.request(
    verb="POST",
    path="/containers/\{percent_encode(id)}/exec",
    op="exec",
    context=EngineOp::container_lifecycle(),
    target=id,
    headers=[("Content-Type", "application/json")],
    body=@utf8.encode(buf.to_string()),
    deadline?,
  )
  let json = try @json.parse(@utf8.decode_lossy(resp.body)) catch {
    _ =>
      raise EngineError::MalformedResponse(
        op="exec",
        detail="exec create body is not JSON",
      )
  } noraise {
    j => j
  }
  match json {
    Object(m) =>
      match m.get("Id") {
        Some(String(s)) if s != "" => s
        _ =>
          raise EngineError::MalformedResponse(
            op="exec",
            detail="exec create response lacks a non-empty Id",
          )
      }
    _ =>
      raise EngineError::MalformedResponse(
        op="exec",
        detail="exec create response is not a JSON object",
      )
  }
}

///|
/// `POST /exec/{id}/start` with `{"Detach":false,"Tty":false}` — the
/// body is the multiplexed stream accumulated to the shared 64 MiB
/// limit. A `application/vnd.docker.raw-stream` Content-Type means a
/// TTY stream that must not be frame-decoded — explicit error.
async fn DockerClient::exec_start(
  self : DockerClient,
  exec_id : String,
  deadline? : Deadline,
) -> HttpResponse {
  let resp = self.request(
    verb="POST",
    path="/exec/\{percent_encode(exec_id)}/start",
    op="exec",
    context=EngineOp::container_lifecycle(),
    target=exec_id,
    headers=[("Content-Type", "application/json")],
    body=@utf8.encode("{\"Detach\":false,\"Tty\":false}"),
    deadline?,
  )
  for (name, value) in resp.headers {
    if ascii_lower(name) == "content-type" &&
      value.contains("application/vnd.docker.raw-stream") {
      raise EngineError::MalformedResponse(
        op="exec",
        detail="exec output is a raw TTY stream, not multiplexed",
      )
    }
  }
  resp
}

///|
/// `GET /exec/{id}/json` as `(running, exit_code)`.
async fn DockerClient::exec_inspect(
  self : DockerClient,
  exec_id : String,
  deadline? : Deadline,
) -> (Bool, Int32?) {
  let resp = self.request(
    verb="GET",
    path="/exec/\{percent_encode(exec_id)}/json",
    op="exec",
    context=EngineOp::container_lifecycle(),
    target=exec_id,
    deadline?,
  )
  parse_exec_inspect_state(resp.body, op="exec")
}

///|
/// Settle budget for the post-EOF exit-code retry when the caller
/// supplied no deadline. Covers the upstream backoff sum (~1.76 s)
/// plus request latency.
const EXEC_SETTLE_BUDGET_MS : Int32 = 10_000

///|
/// Full exec: optional env merge → create → start → demux → inspect
/// with the upstream backoff (initial + 10/50/200/500/1000 ms, max 6
/// attempts, each wait clamped to the deadline). `env` overrides are
/// merged onto `Config.Env` via inspect before create — Docker's
/// `Env` replaces the container env for the exec process.
/// The exit code must settle; `ExecExitUndetermined` is raised rather
/// than faking 0.
pub async fn DockerClient::exec(
  self : DockerClient,
  id : String,
  cmd~ : Array[String],
  env~ : Array[(String, String)] = [],
  deadline? : Deadline,
) -> DockerExecResult {
  let merged_env : Array[String] = if env.length() == 0 {
    []
  } else {
    merge_exec_env(self.inspect_container(id, deadline?).env, env)
  }
  let exec_id = self.exec_create(id, cmd, merged_env, deadline?)
  let resp = self.exec_start(exec_id, deadline?)
  let (stdout, stderr) = demux_exec_stream(resp.body)
  let settle = deadline.unwrap_or(Deadline::after(EXEC_SETTLE_BUDGET_MS))
  for attempt = 0; attempt < ENGINE_RETRY_MAX; attempt = attempt + 1 {
    let (running, exit_code) = self.exec_inspect(exec_id, deadline=settle)
    if !running {
      match exit_code {
        Some(code) => return { exit_code: code, stdout, stderr, }
        None => break
      }
    }
    if attempt + 1 < ENGINE_RETRY_MAX {
      settle.backoff(op="exec", attempt)
    }
  }
  raise EngineError::ExecExitUndetermined(op="exec", exec_id~)
}
