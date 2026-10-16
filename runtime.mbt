///|
/// A container started by this library. Cleanup is explicit in this first port.
pub struct Container {
  id : String
  runtime : Runtime
  mappings : Array[PortMapping]
  mut removed : Bool
}

///|
/// Captured output from an exec or log operation.
pub struct ProcessOutput {
  exit_code : Int
  stdout : String
  stderr : String
}

///|
pub fn ProcessOutput::exit_code(self : ProcessOutput) -> Int {
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
/// Resolve explicitly mapped ports. Dynamically assigned ports require an
/// inspect API and are deliberately not returned as a guessed value.
pub fn Container::get_host_port_ipv4(
  self : Container,
  port : ContainerPort,
) -> Int raise {
  for mapping in self.mappings {
    if same_port(mapping.container_port(), port) && mapping.host_port() != 0 {
      return mapping.host_port()
    }
  }
  fail("no fixed host port mapping for \{port.as_string()}; dynamic port inspection is pending")
}

///|
/// Remaining milliseconds on the same clock used by MoonBit async timers.
fn startup_remaining_ms(deadline : Int64) -> Int raise {
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
fn startup_command_timeout_ms(deadline : Int64, maximum : Int) -> Int raise {
  let remaining = startup_remaining_ms(deadline)
  if remaining < maximum { remaining } else { maximum }
}

///|
/// Run a container via the selected native runtime CLI without a shell.
pub async fn GenericImage::start(self : GenericImage, runtime : Runtime) -> Container {
  let deadline = @async.now() + self.startup_timeout_ms.to_int64()
  let args = build_run_args(runtime, self)
  // Why not retain shared mutable builder arrays across container creation.
  let published_mappings = self.mappings.copy()
  let conditions = self.ready_conditions.copy()
  let result = @shell.Cmd(runtime.executable(), args).output(
    timeout_ms=startup_remaining_ms(deadline),
    max_output_bytes=1048576,
  )
  guard result.exit_code() == 0 else {
    fail("container run failed (exit \{result.exit_code()}): \{result.stderr()}")
  }
  let id = match self.container_name {
    Some(name) => name
    None => result.stdout().trim().to_owned()
  }
  guard id != "" else {
    fail("container runtime returned an empty container ID")
  }
  let container : Container = {
    id,
    runtime,
    mappings: published_mappings,
    removed: false,
  }
  // Why not leave a container running if readiness fails or gets cancelled.
  errdefer {
    container.rm() catch { _ => () }
  }
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
  timeout_ms : Int,
) -> ProcessOutput {
  guard !self.removed else { fail("container already removed") }
  guard timeout_ms > 0 else { fail("log timeout must be positive") }
  let result = @shell.Cmd(
    self.runtime.executable(),
    ["logs", self.id],
  ).output(timeout_ms=timeout_ms, max_output_bytes=67108864)
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
  let result = @shell.Cmd(
    self.runtime.executable(),
    build_stop_args(self.id),
  ).output(timeout_ms=30000, max_output_bytes=1048576)
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
  timeout_ms : Int,
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
