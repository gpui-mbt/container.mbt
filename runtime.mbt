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
/// Run a container via the selected native runtime CLI without a shell.
pub async fn GenericImage::start(self : GenericImage, runtime : Runtime) -> Container {
  let args = build_run_args(runtime, self)
  let result = @shell.Cmd(runtime.executable(), args).output(
    timeout_ms=self.startup_timeout_ms,
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
    mappings: self.mappings,
    removed: false,
  }
  // Why not retain containers if readiness fails or the task is cancelled.
  errdefer {
    container.rm() catch { _ => () }
  }
  container.wait_ready(self.ready_conditions, self.startup_timeout_ms)
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
  guard !self.removed else { fail("container already removed") }
  let result = @shell.Cmd(
    self.runtime.executable(),
    ["logs", self.id],
  ).output(timeout_ms=15000, max_output_bytes=67108864)
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
/// Wait for supported readiness conditions in declaration order.
pub async fn Container::wait_ready(
  self : Container,
  conditions : Array[WaitFor],
  timeout_ms : Int,
) -> Unit {
  guard timeout_ms > 0 else { fail("startup timeout must be positive") }
  for ready in conditions {
    match ready {
      Nothing => ()
      Millis(ms) =>
        if ms < 0 {
          fail("wait duration must not be negative")
        } else {
          @async.sleep(ms)
        }
      MessageOnStdout(message) => self.wait_for_log(message, "stdout", timeout_ms)
      MessageOnStderr(message) => self.wait_for_log(message, "stderr", timeout_ms)
      MessageOnEither(message) => self.wait_for_log(message, "both", timeout_ms)
      Healthcheck | Exit => fail("readiness strategy is not implemented by the CLI adapters")
    }
  }
}

///|
/// Polling is bounded and never starts an unbounded background reader.
async fn Container::wait_for_log(
  self : Container,
  message : String,
  stream : String,
  timeout_ms : Int,
) -> Unit {
  guard message != "" else { return }
  let interval_ms = 250
  let attempts = (timeout_ms + interval_ms - 1) / interval_ms
  for _i = 0; _i < attempts; _i = _i + 1 {
    let logs = self.logs()
    let hit = match stream {
      "stdout" => logs.stdout().contains(message)
      "stderr" => logs.stderr().contains(message)
      _ => logs.stdout().contains(message) || logs.stderr().contains(message)
    }
    if hit {
      return
    }
    @async.sleep(interval_ms)
  }
  fail("container readiness timed out waiting for \{stream} message")
}
