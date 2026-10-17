///|
/// A container started by this library. Cleanup is explicit in this first port.
pub struct Container {
  id : String
  runtime : Runtime
  mappings : Array[PortMapping]
  mut removed : Bool
  /// Lazily cached `docker inspect` port resolution for dynamic ports.
  priv mut resolved_ports : ResolvedPorts?
  /// Lazily cached first object of `docker inspect` output — backs both
  /// dynamic-port (0014) and bridge-IP/network (0015) resolution.
  priv mut inspect_obj : Json?
  /// When `Some`, this container was created through the direct Engine
  /// adapter (issue 0019) and lifecycle operations go over the Unix
  /// socket instead of spawning the CLI.
  priv client : DockerClient?
}

///|
/// Captured output from an exec or log operation.
pub struct ProcessOutput {
  exit_code : Int32
  stdout : String
  stderr : String
}

///|
pub fn ProcessOutput::exit_code(self : ProcessOutput) -> Int32 {
  self.exit_code
}

///|
pub fn ProcessOutput::stdout(self : ProcessOutput) -> String {
  self.stdout
}

///|
pub fn ProcessOutput::stderr(self : ProcessOutput) -> String {
  self.stderr
}

///|
pub fn Container::id(self : Container) -> String {
  self.id
}

///|
pub fn Container::runtime(self : Container) -> Runtime {
  self.runtime
}

///|
/// Resolve explicitly mapped ports, then dynamically assigned ones.
/// Fixed mappings (host port != 0) always win from the snapshot —
/// deterministic, no daemon call. Otherwise `docker inspect`'s
/// `NetworkSettings.Ports` is resolved (cached after first fetch);
/// 0 is never returned — unexposed and unassigned are distinct errors.
pub async fn Container::get_host_port_ipv4(
  self : Container,
  port : ContainerPort,
) -> Int32 {
  for mapping in self.mappings {
    if same_port(mapping.container_port(), port) && mapping.host_port() != 0 {
      return mapping.host_port()
    }
  }
  self.inspect_ports().ipv4(port)
}

///|
/// IPv6 host port for `port`, from inspect bindings only — the IPv4
/// snapshot mappings never apply (0014).
pub async fn Container::get_host_port_ipv6(
  self : Container,
  port : ContainerPort,
) -> Int32 {
  self.inspect_ports().ipv6(port)
}

///|
/// `docker inspect <id>` → first JSON object, fetched once and cached.
/// A failed inspect raises — callers never see an empty object
/// masquerading as "nothing configured".
async fn Container::inspect_object(self : Container) -> Json {
  if self.inspect_obj is Some(obj) {
    return obj
  }
  let result = @shell.Cmd(
    self.runtime.executable(),
    build_inspect_args(self.id),
  ).output(timeout_ms=15000, max_output_bytes=16777216)
  guard result.exit_code() == 0 else {
    fail(
      "container inspect failed (exit \{result.exit_code()}): \{result.stderr()}",
    )
  }
  let obj = match @json.parse(result.stdout()) {
    Array([first, ..]) => first
    other => other
  }
  self.inspect_obj = Some(obj)
  obj
}

///|
/// `docker inspect <id>` → `NetworkSettings.Ports`, resolved once and
/// cached. Direct-path containers use `inspect_container` on the socket
/// instead of spawning `docker inspect`.
async fn Container::inspect_ports(self : Container) -> ResolvedPorts {
  if self.resolved_ports is Some(p) {
    return p
  }
  if self.client is Some(client) {
    let ports = client.inspect_container(self.id).ports
    self.resolved_ports = Some(ports)
    return ports
  }
  let obj = self.inspect_object()
  let ports = match obj {
    Object(m) =>
      match m.get("NetworkSettings") {
        Some(Object(ns)) =>
          match ns.get("Ports") {
            Some(p) => ResolvedPorts::parse(p)
            _ => ResolvedPorts::empty()
          }
        _ => ResolvedPorts::empty()
      }
    _ => ResolvedPorts::empty()
  }
  self.resolved_ports = Some(ports)
  ports
}

///|
/// `docker inspect <id>` → `NetworkSettings.Networks`, normalized to
/// name → `IPAddress` (0015).
async fn Container::inspect_networks(self : Container) -> ContainerNetworks {
  if self.client is Some(client) {
    return client.inspect_container(self.id).networks
  }
  let obj = self.inspect_object()
  match obj {
    Object(m) =>
      match m.get("NetworkSettings") {
        Some(Object(ns)) =>
          match ns.get("Networks") {
            Some(n) => ContainerNetworks::parse(n)
            _ => ContainerNetworks::empty()
          }
        _ => ContainerNetworks::empty()
      }
    _ => ContainerNetworks::empty()
  }
}

///|
/// The container's bridge IP: `IPAddress` of the alphabetically first
/// network (0015). Not-connected, unassigned, and unparsable are
/// distinct errors; the CLI path wraps a failed `docker inspect`.
pub async fn Container::get_bridge_ip_address(self : Container) -> String {
  self.inspect_networks().bridge_ip(container_id=self.id)
}

///|
/// Remaining milliseconds on the same clock used by MoonBit async timers.
fn startup_remaining_ms(deadline : Int64) -> Int32 raise {
  let remaining = deadline - @async.now()
  guard remaining > 0L else { fail("startup timeout exceeded") }
  // Why not truncate an Int64 before applying the Int-sized command timeout.
  if remaining > 2147483647L {
    2147483647
  } else {
    remaining.to_int()
  }
}

///|
/// Clamp a command or polling interval to the shared startup deadline.
fn startup_command_timeout_ms(deadline : Int64, maximum : Int32) -> Int32 raise {
  let remaining = startup_remaining_ms(deadline)
  if remaining < maximum {
    remaining
  } else {
    maximum
  }
}

///|
/// Best-effort check whether a container already holds `name`. An
/// undetermined answer is treated as free so the actual run can report the
/// runtime's own error.
async fn name_in_use_via(executable : String, name : String) -> Bool {
  let probe = @shell.Cmd(executable, build_inspect_args(name)).output(
    timeout_ms=5000,
    max_output_bytes=262144,
  ) catch {
    _ => return false
  }
  probe.exit_code() == 0
}

///|
/// Find and remove the container this run attempt may have created, within a
/// short budget independent of the startup deadline. Only a container whose
/// inspect output carries the attempt's ownership run id is removed; a
/// foreign container with the same name is left untouched. Never raises: the
/// returned note is appended to the original run error.
async fn collect_run_attempt(runtime : Runtime, attempt : RunAttempt) -> String {
  collect_attempt(runtime.executable(), runtime, attempt, 5000)
}

///|
/// Cancellation-safe wrapper so cleanup still runs when the run task itself
/// was cancelled or timed out.
async fn collect_attempt(
  executable : String,
  runtime : Runtime,
  attempt : RunAttempt,
  budget_ms : Int32,
) -> String {
  try
    @async.protect_from_cancel(() => {
      collect_owned_container(executable, runtime, attempt, budget_ms)
    })
  catch {
    _ => "cleanup probe could not complete"
  } noraise {
    outcome => outcome
  }
}

///|
/// Poll briefly for a late create after the CLI run was killed, then remove
/// the container only when the ownership label matches this run.
async fn collect_owned_container(
  executable : String,
  runtime : Runtime,
  attempt : RunAttempt,
  budget_ms : Int32,
) -> String {
  let deadline = @async.now() + budget_ms.to_int64()
  for ;; {
    let probe : @shell.Output? = Some(
      @shell.Cmd(executable, build_inspect_args(attempt.name())).output(
        timeout_ms=1500,
        max_output_bytes=262144,
      ),
    ) catch {
      _ => None
    }
    match probe {
      Some(output) if output.exit_code() == 0 => {
        if !output.stdout().contains(attempt.owner_id()) {
          return "container \{attempt.name()} lacks the ownership label of this run; left untouched"
        }
        let removed : @shell.Output? = Some(
          @shell.Cmd(executable, build_remove_args(runtime, attempt.name())).output(
            timeout_ms=3000,
            max_output_bytes=262144,
          ),
        ) catch {
          _ => None
        }
        match removed {
          Some(done) if done.exit_code() == 0 =>
            return "removed owned container \{attempt.name()}"
          _ =>
            return "owned container \{attempt.name()} could not be removed; it may still exist"
        }
      }
      _ =>
        if @async.now() >= deadline {
          return "no owned container named \{attempt.name()} found"
        } else {
          @async.sleep(250)
        }
    }
  }
}

///|
/// Start a container through the runtime's direct adapter (issue 0019):
/// `Runtime::Docker` resolves to the Docker Engine API on the Unix
/// socket — no `docker` CLI process is spawned — and `AppleContainer`
/// targets the M2 XPC adapter, which fails explicitly (no CLI fallback)
/// until issues 0023+ land. Select the CLI deliberately via `start_cli`.
/// Unsupported settings are rejected by the capability matrix before
/// any pull/create side effect; a direct-transport failure (missing
/// socket, daemon down) propagates as-is.
pub async fn GenericImage::start(
  self : GenericImage,
  runtime : Runtime,
) -> Container {
  let adapter = adapter_for(runtime)
  preflight(adapter, self)
  match adapter {
    DirectDocker => self.start_with_client(DockerClient::new())
    DirectXpc =>
      fail(
        "Apple Container XPC adapter is not yet implemented (issues 0023-0032); use start_cli to select the CLI explicitly",
      )
    CliDocker | CliApple => self.start_via_cli(runtime)
  }
}

///|
/// Explicit CLI adapter selection (0019). This is the only route that
/// spawns `docker`/`container` processes; the CLI adapters are kept for
/// one release beyond the direct adapters' E2E acceptance (issues
/// 0020/0032) and are then slated for removal.
pub async fn GenericImage::start_cli(
  self : GenericImage,
  runtime : Runtime,
) -> Container {
  preflight(cli_adapter_for(runtime), self)
  self.start_via_cli(runtime)
}

///|
/// Direct Engine-API start (0019): resolve/pull → create+start under
/// one startup deadline, then readiness. The returned `Container`
/// carries the client so exec/logs/stop/rm/inspect also use the socket.
/// Separable from `start` so tests can point at a mock daemon.
pub async fn GenericImage::start_with_client(
  self : GenericImage,
  client : DockerClient,
) -> Container {
  preflight(DirectDocker, self)
  let deadline = Deadline::after(self.startup_timeout_ms)
  ignore(ensure_owner_lock())
  let attempt = RunAttempt::prepare(self)
  // Same identity contract as the CLI adapter: the attempt name and the
  // ownership label let a later run find and collect this run's leavings.
  let attempt_image = self
    .with_container_name(attempt.name())
    .with_label(OWNERSHIP_LABEL, attempt.owner_id())
  ignore(client.resolve_or_pull_image(self.descriptor(), deadline~))
  let id = if attempt_image.copy_to.is_empty() {
    client.create_and_start(attempt_image, deadline~)
  } else {
    // create → copy → start: a copy failure must not leave a created
    // container behind, and the original error is what propagates.
    let id = client.create_container(attempt_image, deadline~)
    let needs_rollback : Ref[Bool] = { val: true, }
    errdefer (if needs_rollback.val {
      try
        @async.protect_from_cancel(() => {
          client.remove_container(
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
    })
    let tar = attempt_image.build_copy_archive()
    client.put_container_archive(id, tar, deadline~)
    client.start_container(id, deadline~)
    needs_rollback.val = false
    id
  }
  let container : Container = {
    id,
    runtime: Docker,
    mappings: self.mappings.copy(),
    removed: false,
    resolved_ports: None,
    inspect_obj: None,
    client: Some(client),
  }
  errdefer (container.rm() catch { _ => () })
  container.wait_ready_until(
    self.ready_conditions.copy(),
    @async.now() + deadline.remaining_ms(),
  )
  container
}

///|
/// Run a container via the selected runtime's CLI adapter without a
/// shell — reached only through `start_cli` (0019).
async fn GenericImage::start_via_cli(
  self : GenericImage,
  runtime : Runtime,
) -> Container {
  let deadline = @async.now() + self.startup_timeout_ms.to_int64()
  ignore(ensure_owner_lock())
  let attempt = RunAttempt::prepare(self)
  let args = build_run_args(runtime, self, attempt~)
  if attempt.user_named() &&
    name_in_use_via(runtime.executable(), attempt.name()) {
    fail("container name is already in use: \{attempt.name()}")
  }
  // While the run is in flight no `Container` value exists yet; the flag
  // keeps this cleanup from running again once a `Container` takes over.
  let attempt_pending : Ref[Bool] = { val: true, }
  errdefer (if attempt_pending.val {
    ignore(collect_run_attempt(runtime, attempt))
  })
  // Why not retain shared mutable builder arrays across container creation.
  let published_mappings = self.mappings.copy()
  let conditions = self.ready_conditions.copy()
  let result = @shell.Cmd(runtime.executable(), args).output(
    timeout_ms=startup_remaining_ms(deadline),
    max_output_bytes=1048576,
  )
  guard result.exit_code() == 0 else {
    attempt_pending.val = false
    let note = collect_run_attempt(runtime, attempt)
    fail(
      "container run failed (exit \{result.exit_code()}): \{result.stderr()} (rollback: \{note})",
    )
  }
  let id = match result.stdout().trim() {
    "" => attempt.name()
    output => output.to_owned()
  }
  let container : Container = {
    id,
    runtime,
    mappings: published_mappings,
    removed: false,
    resolved_ports: None,
    inspect_obj: None,
    client: None,
  }
  attempt_pending.val = false
  // Why not leave a container running if readiness fails or gets cancelled.
  errdefer (container.rm() catch { _ => () })
  container.wait_ready_until(conditions, deadline)
  container
}

///|
/// Start a container using the runtime detected from the host OS.
pub async fn GenericImage::start_detected(self : GenericImage) -> Container {
  self.start(detect_runtime())
}

///|
/// Capture stdout and stderr from a one-shot container command.
/// Direct-path containers go through `POST /exec` (0012); CLI-path
/// containers spawn `docker exec`.
pub async fn Container::exec(
  self : Container,
  command : Array[String],
) -> ProcessOutput {
  guard !self.removed else { fail("container already removed") }
  guard command.length() > 0 else { fail("exec command must not be empty") }
  if self.client is Some(client) {
    let r = client.exec(self.id, cmd=command)
    return {
      exit_code: r.exit_code,
      stdout: @utf8.decode_lossy(r.stdout),
      stderr: @utf8.decode_lossy(r.stderr),
    }
  }
  let result = @shell.Cmd(
    self.runtime.executable(),
    build_exec_args(self.id, command),
  ).output(timeout_ms=60000, max_output_bytes=67108864)
  {
    exit_code: result.exit_code(),
    stdout: result.stdout(),
    stderr: result.stderr(),
  }
}

///|
/// Retrieve bounded stdout and stderr logs.
pub async fn Container::logs(self : Container) -> ProcessOutput {
  self.logs_with_timeout(15000)
}

///|
/// Allow startup readiness to shorten a CLI log read to remaining time.
/// Direct-path containers use `GET /containers/{id}/logs` (0013)
/// bounded to the shared deadline instead.
async fn Container::logs_with_timeout(
  self : Container,
  timeout_ms : Int32,
) -> ProcessOutput {
  guard !self.removed else { fail("container already removed") }
  guard timeout_ms > 0 else { fail("log timeout must be positive") }
  if self.client is Some(client) {
    let logs = client.logs(self.id, deadline=Deadline::after(timeout_ms))
    return {
      exit_code: 0,
      stdout: @utf8.decode_lossy(logs.stdout),
      stderr: @utf8.decode_lossy(logs.stderr),
    }
  }
  let result = @shell.Cmd(self.runtime.executable(), ["logs", self.id]).output(
    timeout_ms~,
    max_output_bytes=67108864,
  )
  guard result.exit_code() == 0 else {
    fail("container logs failed (exit \{result.exit_code()})")
  }
  {
    exit_code: result.exit_code(),
    stdout: result.stdout(),
    stderr: result.stderr(),
  }
}

///|
/// Stop an owned container without deleting it.
pub async fn Container::stop(self : Container) -> Unit {
  guard !self.removed else { fail("container already removed") }
  if self.client is Some(client) {
    return client.stop_container(self.id)
  }
  let result = @shell.Cmd(self.runtime.executable(), build_stop_args(self.id)).output(
    timeout_ms=30000,
    max_output_bytes=1048576,
  )
  guard result.exit_code() == 0 else {
    fail("container stop failed (exit \{result.exit_code()})")
  }
}

///|
/// Explicitly delete the container, even when it is still running.
pub async fn Container::rm(self : Container) -> Unit {
  if self.removed {
    return
  }
  if self.client is Some(client) {
    client.remove_container(self.id, force=true)
    self.removed = true
    return
  }
  let result = @shell.Cmd(
    self.runtime.executable(),
    build_remove_args(self.runtime, self.id),
  ).output(timeout_ms=30000, max_output_bytes=1048576)
  guard result.exit_code() == 0 else {
    fail("container remove failed (exit \{result.exit_code()})")
  }
  self.removed = true
}

///|
/// Start an independent readiness budget for callers outside start().
pub async fn Container::wait_ready(
  self : Container,
  conditions : Array[WaitFor],
  timeout_ms : Int32,
) -> Unit {
  guard timeout_ms > 0 else { fail("startup timeout must be positive") }
  let deadline = @async.now() + timeout_ms.to_int64()
  self.wait_ready_until(conditions, deadline)
}

///|
/// Share the deadline created before CLI run across all readiness conditions.
async fn Container::wait_ready_until(
  self : Container,
  conditions : Array[WaitFor],
  deadline : Int64,
) -> Unit {
  for ready in conditions {
    let remaining = startup_remaining_ms(deadline)
    match ready {
      Nothing => ()
      Millis(ms) => {
        guard ms >= 0 else { fail("wait duration must not be negative") }
        if ms > remaining {
          // Why not sleep past the total deadline when one condition is too long.
          @async.sleep(remaining)
          fail("startup timeout exceeded")
        }
        @async.sleep(ms)
      }
      MessageOnStdout(message) =>
        self.wait_for_log_until(message, "stdout", deadline)
      MessageOnStderr(message) =>
        self.wait_for_log_until(message, "stderr", deadline)
      MessageOnEither(message) =>
        self.wait_for_log_until(message, "both", deadline)
      Healthcheck | Exit =>
        fail("readiness strategy is not implemented by the CLI adapters")
      Http(strategy) => self.http_wait_until(strategy, deadline)
    }
  }
  ignore(startup_remaining_ms(deadline))
}

///|
/// Poll logs only while there is time left for this and earlier conditions.
async fn Container::wait_for_log_until(
  self : Container,
  message : String,
  stream : String,
  deadline : Int64,
) -> Unit {
  guard message != "" else { return }
  while true {
    // Why not give each logs subprocess a fresh fifteen-second allowance.
    let budget = startup_command_timeout_ms(deadline, 15000)
    let logs = self.logs_with_timeout(budget)
    let hit = match stream {
      "stdout" => logs.stdout().contains(message)
      "stderr" => logs.stderr().contains(message)
      _ => logs.stdout().contains(message) || logs.stderr().contains(message)
    }
    ignore(startup_remaining_ms(deadline))
    if hit {
      return
    }
    @async.sleep(startup_command_timeout_ms(deadline, 250))
  }
}

///|
/// `copy_file_from` (issue 0034): read the single regular file at
/// `path` inside the container and return its bytes. Direct-adapter
/// only — the archive API is the M1+ contract, so CLI-created
/// containers report an explicit not-yet-implemented error instead of
/// falling back to `docker cp`. Directory paths raise `IsDirectory`,
/// a missing container path raises `ContainerPathNotFound`, a missing
/// container `ContainerNotFound`; corrupt/truncated tars and bodies
/// over 64 MiB fail closed — partial payload is never returned.
pub async fn Container::copy_file_from(
  self : Container,
  path : String,
) -> Bytes {
  guard !self.removed else { fail("container already removed") }
  guard !path.is_empty() else { fail("container path must not be empty") }
  match self.client {
    Some(client) => client.copy_file_from(self.id, path)
    None =>
      fail(
        "copy_file_from is only supported on the direct adapter (issue 0034); CLI adapters are NotYetImplemented(34)",
      )
  }
}

///|
/// `copy_file_from` writing to a host file — upstream's PathBuf
/// `CopyFileFromContainer` form. A relative `dest` resolves against the
/// caller's cwd. The file is created only after the full payload is
/// validated in memory, so a failed copy never leaves a partial file.
pub async fn Container::copy_file_to_host(
  self : Container,
  path : String,
  dest~ : String,
) -> Unit {
  let bytes = self.copy_file_from(path)
  let abs = if dest.has_prefix("/") {
    dest
  } else {
    match @env.current_dir() {
      Some(cwd) => "\{cwd}/\{dest}"
      None => fail("cannot resolve relative destination: \{dest}")
    }
  }
  @fs.write_file(abs, bytes[:])
}
