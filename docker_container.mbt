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

// M1 container create/start (issue 0010). Ports upstream
// `CreateContainerBody::from_config` / `create_container` /
// `start_container` and the runner's `rollback_remove`: on start
// failure only the id returned by create is force-removed, under an
// independent cleanup budget, never overwriting the start error.
// No CLI process is involved.

///|
/// JSON string escape — upstream `escape_json_value`: quotes,
/// backslash, the short escapes, other <0x20 as \uXXXX. Shared by the
/// create/exec serializers and registry auth (0016).
fn escape_json(s : String) -> String {
  let buf = StringBuilder()
  buf.write_char('"')
  for c in s {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\u{08}' => buf.write_string("\\b")
      '\u{0c}' => buf.write_string("\\f")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      _ =>
        if c.to_int() < 0x20 {
          let hex = "0123456789abcdef"
          let u = c.to_int()
          buf.write_string("\\u")
          buf.write_char(hex[(u >> 12) & 0xF].unsafe_to_char())
          buf.write_char(hex[(u >> 8) & 0xF].unsafe_to_char())
          buf.write_char(hex[(u >> 4) & 0xF].unsafe_to_char())
          buf.write_char(hex[u & 0xF].unsafe_to_char())
        } else {
          buf.write_char(c)
        }
    }
  }
  buf.write_char('"')
  buf.to_string()
}

///|
/// `["a","b"]` — upstream `json_array`.
fn json_array(items : Array[String]) -> String {
  let buf = StringBuilder()
  buf.write_char('[')
  for i = 0; i < items.length(); i = i + 1 {
    if i > 0 {
      buf.write_char(',')
    }
    buf.write_string(escape_json(items[i]))
  }
  buf.write_char(']')
  buf.to_string()
}

///|
/// `{"k":"v"}` — upstream `json_object`.
fn json_object(pairs : Array[(String, String)]) -> String {
  let buf = StringBuilder()
  buf.write_char('{')
  for i = 0; i < pairs.length(); i = i + 1 {
    if i > 0 {
      buf.write_char(',')
    }
    buf.write_string(escape_json(pairs[i].0))
    buf.write_char(':')
    buf.write_string(escape_json(pairs[i].1))
  }
  buf.write_char('}')
  buf.to_string()
}

///|
/// Frozen view of `GenericImage` at request-build time — later builder
/// mutations cannot leak into the create body (issue 0010 snapshot
/// contract, same rule as `mappings()`).
priv struct CreateRequest {
  image : String
  name : String?
  platform : String?
  entrypoint : String?
  cmd : Array[String]
  env : Array[String]
  labels : Array[(String, String)]
  working_dir : String?
  user : String?
  network : String?
  readonly_rootfs : Bool
  /// `{port}/{proto}` keys for `ExposedPorts`/`PortBindings`.
  exposed : Array[String]
  /// `(key, host_ip, host_port)` rows for `HostConfig.PortBindings`.
  bindings : Array[(String, String, String)]
  binds : Array[String]
  mounts : Array[String]
  healthcheck : String?
  hostname : String?
  /// `host:ip` strings for `HostConfig.ExtraHosts` (0045).
  extra_hosts : Array[String]
}

///|
/// Port of upstream `CreateContainerBody::from_config` for our
/// `GenericImage` surface. Bind mounts go to `Binds`
/// (`src:dst:ro|rw`), volumes/tmpfs to `HostConfig.Mounts` entries.
fn create_request(image : GenericImage) -> CreateRequest raise {
  validate_image_request(image)
  let exposed : Array[String] = []
  let bindings : Array[(String, String, String)] = []
  for m in image.mappings {
    let port = m.container_port()
    let key = port.as_string()
    exposed.push(key)
    bindings.push((key, "0.0.0.0", m.host_port().to_string()))
  }
  let binds : Array[String] = []
  let mounts : Array[String] = []
  let extra_hosts : Array[String] = []
  for (key, host) in image.extra_hosts {
    let value = match host {
      Addr(addr) => addr
      HostGateway => "host-gateway"
    }
    extra_hosts.push("\{key}:\{value}")
  }
  for m in image.mounts {
    match m {
      Bind(src, dst, ro) =>
        binds.push("\{src}:\{dst}:\{if ro is ReadOnly { "ro" } else { "rw" }}")
      Volume(src, dst, ro) =>
        mounts.push(
          "{\"Type\":\"volume\",\"Source\":\{escape_json(src)},\"Target\":\{escape_json(dst)},\"ReadOnly\":\{ro is ReadOnly}}",
        )
      Tmpfs(dst, ro, opts) => {
        let mut entry = "{\"Type\":\"tmpfs\",\"Target\":\{escape_json(dst)},\"ReadOnly\":\{ro is ReadOnly}"
        if opts.size_bytes is Some(_) || opts.mode is Some(_) {
          entry = entry + ",\"TmpfsOptions\":{"
          let mut first = true
          if opts.size_bytes is Some(bytes) {
            entry = entry + "\"SizeBytes\":\{bytes}"
            first = false
          }
          if opts.mode is Some(mode) {
            if !first {
              entry = entry + ","
            }
            entry = entry + "\"Mode\":\{mode}"
          }
          entry = entry + "}"
        }
        mounts.push(entry + "}")
      }
    }
  }
  let env : Array[String] = []
  for (k, v) in image.env_vars {
    env.push("\{k}=\{v}")
  }
  {
    image: image.descriptor(),
    name: image.container_name,
    platform: image.platform,
    entrypoint: image.entrypoint,
    cmd: image.command.copy(),
    env,
    labels: image.labels.copy(),
    working_dir: image.working_dir,
    user: image.user,
    network: image.network,
    hostname: image.hostname,
    extra_hosts,
    readonly_rootfs: image.readonly_rootfs,
    exposed,
    bindings,
    binds,
    mounts,
    healthcheck: match image.healthcheck {
      Some(hc) => hc.to_docker_json()
      None => None
    },
  }
}

///|
/// Serialize in upstream's member order. `HostConfig` always carries
/// `Privileged:false` / `Init:false` like upstream defaults.
fn CreateRequest::to_json(self : CreateRequest) -> String {
  let buf = StringBuilder()
  buf.write_string("{\"Image\":")
  buf.write_string(escape_json(self.image))
  if self.entrypoint is Some(e) {
    buf.write_string(",\"Entrypoint\":")
    buf.write_string(json_array([e]))
  }
  if self.cmd.length() > 0 {
    buf.write_string(",\"Cmd\":")
    buf.write_string(json_array(self.cmd))
  }
  if self.env.length() > 0 {
    buf.write_string(",\"Env\":")
    buf.write_string(json_array(self.env))
  }
  if self.labels.length() > 0 {
    buf.write_string(",\"Labels\":")
    buf.write_string(json_object(self.labels))
  }
  if self.working_dir is Some(wd) {
    buf.write_string(",\"WorkingDir\":")
    buf.write_string(escape_json(wd))
  }
  if self.user is Some(u) {
    buf.write_string(",\"User\":")
    buf.write_string(escape_json(u))
  }
  if self.hostname is Some(h) {
    buf.write_string(",\"Hostname\":")
    buf.write_string(escape_json(h))
  }
  if self.exposed.length() > 0 {
    buf.write_string(",\"ExposedPorts\":{")
    for i = 0; i < self.exposed.length(); i = i + 1 {
      if i > 0 {
        buf.write_char(',')
      }
      buf.write_string(escape_json(self.exposed[i]))
      buf.write_string(":{}")
    }
    buf.write_char('}')
  }
  if self.healthcheck is Some(hc) {
    buf.write_string(",\"Healthcheck\":")
    buf.write_string(hc)
  }
  if self.network is Some(n) {
    buf.write_string(",\"NetworkingConfig\":{\"EndpointsConfig\":{")
    buf.write_string(escape_json(n))
    buf.write_string(":{}}}")
  }
  buf.write_string(
    ",\"HostConfig\":{\"Privileged\":false,\"Init\":false,\"ReadonlyRootfs\":",
  )
  buf.write_string(if self.readonly_rootfs { "true" } else { "false" })
  if self.binds.length() > 0 {
    buf.write_string(",\"Binds\":")
    buf.write_string(json_array(self.binds))
  }
  if self.bindings.length() > 0 {
    buf.write_string(",\"PortBindings\":{")
    for i = 0; i < self.bindings.length(); i = i + 1 {
      if i > 0 {
        buf.write_char(',')
      }
      let (key, ip, host) = self.bindings[i]
      buf.write_string(escape_json(key))
      buf.write_string(
        ":[{\"HostIp\":\{escape_json(ip)},\"HostPort\":\{escape_json(host)}}]",
      )
    }
    buf.write_char('}')
  }
  if self.extra_hosts.length() > 0 {
    buf.write_string(",\"ExtraHosts\":")
    buf.write_string(json_array(self.extra_hosts))
  }
  if self.mounts.length() > 0 {
    buf.write_string(",\"Mounts\":[")
    for i = 0; i < self.mounts.length(); i = i + 1 {
      if i > 0 {
        buf.write_char(',')
      }
      buf.write_string(self.mounts[i])
    }
    buf.write_char(']')
  }
  buf.write_string("}}")
  buf.to_string()
}

///|
/// `POST /containers/create[?name=..&platform=..]` — the request body
/// is the `CreateRequest` JSON; the response must carry a non-empty
/// `Id`. Validates the request before any socket traffic.
pub async fn DockerClient::create_container(
  self : DockerClient,
  image : GenericImage,
  deadline? : Deadline,
) -> String {
  let req = try create_request(image) catch {
    err =>
      raise EngineError::BadRequest(
        op="create container",
        message=err.to_string(),
      )
  } noraise {
    r => r
  }
  let mut path = "/containers/create"
  let params : Array[String] = []
  if req.name is Some(n) {
    params.push("name=\{percent_encode(n)}")
  }
  if req.platform is Some(p) {
    params.push("platform=\{percent_encode(p)}")
  }
  if params.length() > 0 {
    path = "\{path}?\{params.join("&")}"
  }
  let body = @utf8.encode(req.to_json())
  let resp = self.request(
    verb="POST",
    path~,
    op="create container",
    context=EngineOp::container_lifecycle(),
    target=req.name.unwrap_or(req.image),
    headers=[("Content-Type", "application/json")],
    body~,
    deadline?,
  )
  let json = try @json.parse(@utf8.decode_lossy(resp.body)) catch {
    _ =>
      raise EngineError::MalformedResponse(
        op="create container",
        detail="response body is not JSON",
      )
  } noraise {
    j => j
  }
  match json {
    Object(m) =>
      match m.get("Id") {
        Some(String(id)) if id != "" => id
        _ =>
          raise EngineError::MalformedResponse(
            op="create container",
            detail="response lacks a non-empty Id",
          )
      }
    _ =>
      raise EngineError::MalformedResponse(
        op="create container",
        detail="response is not a JSON object",
      )
  }
}

///|
/// `POST /containers/{id}/start` — empty body, any 2xx is success.
pub async fn DockerClient::start_container(
  self : DockerClient,
  id : String,
  deadline? : Deadline,
) -> Unit {
  ignore(
    self.request(
      verb="POST",
      path="/containers/\{percent_encode(id)}/start",
      op="start container",
      context=EngineOp::container_lifecycle(),
      target=id,
      deadline?,
    ),
  )
}

///|
/// `PUT /containers/{id}/archive?path=/&copyUIDGID=true` — upload the
/// tar built from `with_copy_to` sources while the container exists
/// but is not yet started (0033).
pub async fn DockerClient::put_container_archive(
  self : DockerClient,
  id : String,
  tar : Bytes,
  deadline? : Deadline,
) -> Unit {
  ignore(
    self.request(
      verb="PUT",
      path="/containers/\{percent_encode(id)}/archive?path=%2F&copyUIDGID=true",
      body=tar,
      headers=[("Content-Type", "application/x-tar")],
      op="copy to container",
      context=EngineOp::container_lifecycle(),
      target=id,
      deadline?,
    ),
  )
}

///|
/// Response-wait margin past the `t` grace for `stop_container` —
/// upstream keeps the transport wait separate from the Docker grace.
const DOCKER_STOP_MARGIN_MS : Int32 = 10_000

///|
/// Independent bound for `remove_container` when the caller supplies
/// no deadline (upstream `remove_blocking` uses 60 s).
const DOCKER_REMOVE_TIMEOUT_MS : Int32 = 60_000

///|
/// Subset of `GET /containers/{id}/json` we act on. Shared snapshot —
/// `ports` (issue 0014) is `NetworkSettings.Ports` resolved into
/// IPv4/IPv6 host-port maps, `networks` (0015) is
/// `NetworkSettings.Networks` normalized to name → `IPAddress`.
pub struct ContainerInspect {
  running : Bool
  exit_code : Int32?
  /// `State.Health.Status` — Some only when the daemon reports one
  /// (issue 0037): "starting" / "healthy" / "unhealthy".
  health : String?
  /// `Config.Env` as `["KEY=VALUE", ...]` — used by exec env merge (0012).
  env : Array[String]
  ports : ResolvedPorts
  networks : ContainerNetworks
}

///|
/// `GET /containers/{id}/json` — 404 is `ContainerNotFound` via the
/// shared classifier. `State` must be an object; `Running` defaults to
/// false when absent, `ExitCode` is read when present.
pub async fn DockerClient::inspect_container(
  self : DockerClient,
  id : String,
  deadline? : Deadline,
) -> ContainerInspect {
  let resp = self.request(
    verb="GET",
    path="/containers/\{percent_encode(id)}/json",
    op="inspect container",
    context=EngineOp::container_lifecycle(),
    target=id,
    deadline?,
  )
  let json = try @json.parse(@utf8.decode_lossy(resp.body)) catch {
    _ =>
      raise EngineError::MalformedResponse(
        op="inspect container",
        detail="response body is not JSON",
      )
  } noraise {
    j => j
  }
  match json {
    Object(m) =>
      match m.get("State") {
        Some(Object(s)) => {
          let running = match s.get("Running") {
            Some(True) => true
            _ => false
          }
          let exit_code = match s.get("ExitCode") {
            Some(Number(n, ..)) => Some(n.to_int())
            _ => None
          }
          let env : Array[String] = []
          if m.get("Config") is Some(Object(c)) &&
            c.get("Env") is Some(Array(e)) {
            for item in e {
              if item is String(v) {
                env.push(v)
              }
            }
          }
          let (ports, networks) = match m.get("NetworkSettings") {
            Some(Object(ns)) => {
              let ports = match ns.get("Ports") {
                Some(p) => ResolvedPorts::parse(p)
                _ => ResolvedPorts::empty()
              }
              let networks = match ns.get("Networks") {
                Some(n) => ContainerNetworks::parse(n)
                _ => ContainerNetworks::empty()
              }
              (ports, networks)
            }
            _ => (ResolvedPorts::empty(), ContainerNetworks::empty())
          }
          let health = match s.get("Health") {
            Some(Object(h)) =>
              match h.get("Status") {
                Some(String(st)) => Some(st)
                _ => None
              }
            _ => None
          }
          { running, exit_code, env, ports, networks, health, }
        }
        _ =>
          raise EngineError::MalformedResponse(
            op="inspect container",
            detail="response lacks a State object",
          )
      }
    _ =>
      raise EngineError::MalformedResponse(
        op="inspect container",
        detail="response is not a JSON object",
      )
  }
}

///|
/// `POST /containers/{id}/stop?t={t}` — upstream `t` normalization:
/// None/negative → 30, `t >= 0` sent as-is (`t=0` is grace 0, never
/// rounded up). 404 (already gone) and 304 (already stopped) are
/// idempotent successes — we cannot tell our own delete from another
/// actor's, so both pass. Without a caller deadline the wait is
/// `t` seconds + `DOCKER_STOP_MARGIN_MS`.
pub async fn DockerClient::stop_container(
  self : DockerClient,
  id : String,
  timeout_seconds? : Int32,
  deadline? : Deadline,
) -> Unit {
  let t = match timeout_seconds {
    Some(t) if t >= 0 => t
    _ => 30
  }
  let dl = deadline.unwrap_or(Deadline::after(t * 1000 + DOCKER_STOP_MARGIN_MS))
  try
    self.request(
      verb="POST",
      path="/containers/\{percent_encode(id)}/stop?t=\{t}",
      op="stop container",
      context=EngineOp::container_lifecycle(),
      target=id,
      deadline=dl,
    )
  catch {
    EngineError::ContainerNotFound(..)
    | EngineError::UnexpectedStatus(status=304, ..) => ()
    err => raise err
  } noraise {
    _ => ()
  }
}

///|
/// `DELETE /containers/{id}[?force=true]` — 404 is an idempotent
/// success (another actor may have deleted first; the target is still
/// only ever the id create returned). The public `rm()` contract keeps
/// `force=true` like upstream `ContainerAsync::rm` — graceful stopping
/// is `stop_container`'s job, documented in 0041's terms.
pub async fn DockerClient::remove_container(
  self : DockerClient,
  id : String,
  force~ : Bool = false,
  deadline? : Deadline,
) -> Unit {
  let mut path = "/containers/\{percent_encode(id)}"
  if force {
    path = "\{path}?force=true"
  }
  let dl = deadline.unwrap_or(Deadline::after(DOCKER_REMOVE_TIMEOUT_MS))
  try
    self.request(
      verb="DELETE",
      path~,
      op="remove container",
      context=EngineOp::container_lifecycle(),
      target=id,
      deadline=dl,
    )
  catch {
    EngineError::ContainerNotFound(..) => ()
    err => raise err
  } noraise {
    _ => ()
  }
}

///|

///|
/// Inspect then resolve the IPv4 host port for `port` — the API-path
/// counterpart of `Container::get_host_port_ipv4` (0014). Never returns
/// 0; unexposed vs exposed-but-unassigned are distinct errors.
pub async fn DockerClient::get_host_port_ipv4(
  self : DockerClient,
  id : String,
  port : ContainerPort,
  deadline? : Deadline,
) -> Int32 {
  self.inspect_container(id, deadline?).ports.ipv4(port)
}

///|
/// IPv6 host port for `port` — only inspect bindings (`HostIp`
/// containing `:`) count; IPv4 snapshot mappings never do.
pub async fn DockerClient::get_host_port_ipv6(
  self : DockerClient,
  id : String,
  port : ContainerPort,
  deadline? : Deadline,
) -> Int32 {
  self.inspect_container(id, deadline?).ports.ipv6(port)
}

///|
/// The container's bridge IP: the `IPAddress` of the first network in
/// alphabetical key order (the upstream `bridge_ip_address` rule).
/// Not-connected, unassigned, and unparsable are distinct errors;
/// container-not-found propagates as `ContainerNotFound` (0017).
pub async fn DockerClient::get_bridge_ip_address(
  self : DockerClient,
  id : String,
  deadline? : Deadline,
) -> String {
  self.inspect_container(id, deadline?).networks.bridge_ip(container_id=id)
}

///|
/// `POST /containers/{id}/wait?condition=not-running` — returns the
/// container's `StatusCode`. 404 stays an explicit `ContainerNotFound`
/// error (never a fabricated 0). No dedicated timeout: a wait can
/// legitimately block for the container's whole lifetime, so callers
/// bound it with `deadline` or task cancellation (0018).
pub async fn DockerClient::wait_container(
  self : DockerClient,
  id : String,
  deadline? : Deadline,
) -> Int32 {
  let resp = self.request(
    verb="POST",
    path="/containers/\{percent_encode(id)}/wait?condition=not-running",
    op="wait container",
    context=EngineOp::container_lifecycle(),
    target=id,
    deadline?,
  )
  let json = try @json.parse(@utf8.decode_lossy(resp.body)) catch {
    _ =>
      raise EngineError::MalformedResponse(
        op="wait container",
        detail="response body is not JSON",
      )
  } noraise {
    j => j
  }
  match json {
    Object(m) =>
      match m.get("StatusCode") {
        Some(Number(n, ..)) => n.to_int()
        _ =>
          raise EngineError::MalformedResponse(
            op="wait container",
            detail="response lacks a StatusCode",
          )
      }
    _ =>
      raise EngineError::MalformedResponse(
        op="wait container",
        detail="response is not a JSON object",
      )
  }
}

///|
/// Create then start. On start failure the created id — and only that
/// id — is force-removed under `CLEANUP_BUDGET_MS`, cancellation-safe,
/// and the original start error is re-raised (upstream
/// `rollback_remove`). Rollback is skipped when
/// `TESTCONTAINERS_COMMAND=keep`, matching upstream.
pub async fn DockerClient::create_and_start(
  self : DockerClient,
  image : GenericImage,
  deadline? : Deadline,
) -> String {
  let id = self.create_container(image, deadline?)
  // Roll back only the id create returned, under an independent budget
  // (upstream `rollback_remove`; `TESTCONTAINERS_COMMAND=keep` opts out).
  let needs_rollback : Ref[Bool] = { val: true, }
  errdefer (if needs_rollback.val {
    if @env.get_env_var("TESTCONTAINERS_COMMAND") != Some("keep") {
      try
        @async.protect_from_cancel(() => {
          self.remove_container(
            id,
            force=true,
            deadline=Deadline::after(CLEANUP_BUDGET_MS),
          )
        })
      catch {
        _ => ()
      } noraise {
        _ => ()
      }
    }
  })
  self.start_container(id, deadline?)
  needs_rollback.val = false
  id
}

///|
/// `GET /containers/{id}/archive?path=...` then parse the leading
/// ustar entry (issue 0034). A 404 splits via `EngineOp::archive()`:
/// daemon `message` starting with "Could not find the file " →
/// `ContainerPathNotFound`, otherwise `ContainerNotFound`. The whole
/// body is bounded by `ARCHIVE_MAX_BYTES`; a corrupt or truncated tar
/// raises `TarReadError` and never yields partial payload.
pub async fn DockerClient::copy_file_from(
  self : DockerClient,
  id : String,
  path : String,
  deadline? : Deadline,
) -> Bytes {
  let resp = self.request(
    verb="GET",
    path="/containers/\{percent_encode(id)}/archive?path=\{percent_encode(path)}",
    op="copy from container",
    context=EngineOp::archive(),
    target=id,
    container_path=path,
    body_limit=ARCHIVE_MAX_BYTES.to_int(),
    deadline?,
  )
  parse_first_regular_file(resp.body)
}

///|
/// `GET /networks/{name}` — 0045 network existence preflight. 404 maps
/// to `false`; every other error propagates. Exactly one request — the
/// check never creates the network.
pub async fn DockerClient::network_exists(
  self : DockerClient,
  name : String,
  deadline? : Deadline,
) -> Bool {
  try {
    ignore(
      self.request(
        verb="GET",
        path="/networks/\{name}",
        op="network inspect",
        deadline?,
      ),
    )
    true
  } catch {
    // The lifecycle context classifies a 404 as ContainerNotFound; for a
    // networks query that same status means "network absent".
    EngineError::ContainerNotFound(..) => false
    e => raise e
  }
}
