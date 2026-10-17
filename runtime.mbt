///|
/// A container started by this library. Cleanup is explicit in this first port.
pub struct Container {
  id : String
  runtime : Runtime
  mappings : Array[PortMapping]
  mut removed : Bool
  /// Lazily cached `docker inspect` port resolution for dynamic ports.
  priv mut resolved_ports : ResolvedPorts?
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
/// `docker inspect <id>` → `NetworkSettings.Ports`, resolved once and
/// cached. A failed inspect raises (never an empty map masquerading as
/// "nothing exposed").
async fn Container::inspect_ports(self : Container) -> ResolvedPorts {
  if self.resolved_ports is Some(p) {
    return p
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
  let json = @json.parse(result.stdout())
  let ports = match json {
    Array([first, ..]) =>
      match first {
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
    _ => ResolvedPorts::empty()
  }
  self.resolved_ports = Some(ports)
  ports
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
        if !output.stdout().contains(attempt.run_id()) {
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
/// Run a container via the selected native runtime CLI without a shell.
pub async fn GenericImage::start(
  self : GenericImage,
  runtime : Runtime,
) -> Container {
  let deadline = @async.now() + self.startup_timeout_ms.to_int64()
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
pub async fn Container::exec(
  self : Container,
  command : Array[String],
) -> ProcessOutput {
  guard !self.removed else { fail("container already removed") }
  guard command.length() > 0 else { fail("exec command must not be empty") }
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
async fn Container::logs_with_timeout(
  self : Container,
  timeout_ms : Int32,
) -> ProcessOutput {
  guard !self.removed else { fail("container already removed") }
  guard timeout_ms > 0 else { fail("log timeout must be positive") }
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
