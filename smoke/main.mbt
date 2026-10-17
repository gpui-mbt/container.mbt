///|
/// Exercise the actual Docker Engine through the native CLI adapter.
async fn main {
  let image = @container.GenericImage::new("alpine", "3.20")
    .with_cmd(["tail", "-f", "/dev/null"])
    .with_exposed_port(@container.ContainerPort::tcp(80))
  let container = image.start(@container.Docker)
  // Why not strand containers if a later assertion fails or the task is cancelled.
  errdefer (container.rm() catch { _ => () })
  // What: mutations after start must not change the reported host mappings.
  ignore(image.with_mapped_port(18081, @container.ContainerPort::tcp(81)))
  let leaked = image.mappings()
  leaked.push(
    @container.PortMapping::new(18082, @container.ContainerPort::tcp(82)),
  )
  let incorrectly_published = try {
    ignore(container.get_host_port_ipv4(@container.ContainerPort::tcp(81)))
    true
  } catch {
    _ => false
  }
  guard !incorrectly_published else {
    fail("started container's port mapping changed with the image builder")
  }
  // What: a delay and a missing log share one readiness budget, not two.
  let wait_started = @async.now()
  let expired = try {
    container.wait_ready(
      [
        @container.WaitFor::millis(220),
        @container.WaitFor::message_on_stdout("never-printed-container-mbt"),
      ],
      400,
    )
    false
  } catch {
    _ => true
  }
  guard expired && @async.now() - wait_started < 1300L else {
    fail("readiness exceeded the shared startup timeout")
  }
  let response = container.exec(["sh", "-c", "printf moonbit-smoke"])
  guard response.exit_code() == 0 else {
    fail("docker exec failed: \{response.stderr()}")
  }
  guard response.stdout() == "moonbit-smoke" else {
    fail("unexpected docker exec stdout: \{response.stdout()}")
  }
  let logs = container.logs()
  guard logs.exit_code() == 0 else { fail("docker logs returned nonzero exit") }
  container.stop()
  container.rm()
  // What: a readiness timeout after successful run must remove the new container.
  let cleanup_name = "container-mbt-timeout-\{@async.now()}"
  let failing_image = @container.GenericImage::new("alpine", "3.20")
    .with_container_name(cleanup_name)
    .with_cmd(["tail", "-f", "/dev/null"])
    .with_wait_for(@container.WaitFor::millis(10000))
    .with_startup_timeout(2500)
  let rejected = try {
    let unexpected = failing_image.start(@container.Docker)
    unexpected.rm()
    false
  } catch {
    _ => true
  }
  guard rejected else {
    fail("startup deadline failed to reject slow readiness")
  }
  let probe = @shell.Cmd("docker", ["inspect", cleanup_name]).output(
    timeout_ms=15000,
    max_output_bytes=1048576,
  )
  guard probe.exit_code() != 0 else {
    // Why not leave an orphan behind when the regression assertion fails.
    ignore(
      @shell.Cmd("docker", ["rm", "--force", cleanup_name]).output(
        timeout_ms=15000,
        max_output_bytes=1048576,
      ),
    )
    fail("readiness failure left a Docker container behind")
  }
  // What: a run that fails before printing an ID must not strand a container.
  let orphan_probe = "container-mbt-orphan-\{@async.now()}"
  let broken_image = @container.GenericImage::new("alpine", "3.20")
    .with_container_name(orphan_probe)
    .with_entrypoint("/definitely/missing/container-mbt-binary")
  let run_rejected = try {
    let unexpected = broken_image.start(@container.Docker)
    unexpected.rm()
    false
  } catch {
    _ => true
  }
  guard run_rejected else {
    fail("run with a missing entrypoint unexpectedly started")
  }
  let leftover = @shell.Cmd("docker", ["inspect", orphan_probe]).output(
    timeout_ms=15000,
    max_output_bytes=1048576,
  )
  guard leftover.exit_code() != 0 else {
    ignore(
      @shell.Cmd("docker", ["rm", "--force", orphan_probe]).output(
        timeout_ms=15000,
        max_output_bytes=1048576,
      ),
    )
    fail("failed run left an orphaned container behind")
  }
  // What: a user-specified name that already exists must fail before run.
  let holder_name = "container-mbt-holder-\{@async.now()}"
  let holder = @shell.Cmd("docker", [
    "run", "--detach", "--name", holder_name, "alpine:3.20", "tail", "-f", "/dev/null",
  ]).output(timeout_ms=30000, max_output_bytes=1048576)
  guard holder.exit_code() == 0 else {
    fail(
      "failed to create the pre-existing holder container: \{holder.stderr()}",
    )
  }
  errdefer ignore(
    @shell.Cmd("docker", ["rm", "--force", holder_name]).output(
      timeout_ms=15000,
      max_output_bytes=1048576,
    ),
  )
  let colliding = @container.GenericImage::new("alpine", "3.20")
    .with_container_name(holder_name)
    .with_cmd(["tail", "-f", "/dev/null"])
  let refused = try {
    let unexpected = colliding.start(@container.Docker)
    unexpected.rm()
    false
  } catch {
    _ => true
  }
  guard refused else {
    fail("a colliding container name was not refused before run")
  }
  let holder_probe = @shell.Cmd("docker", ["inspect", holder_name]).output(
    timeout_ms=15000,
    max_output_bytes=1048576,
  )
  guard holder_probe.exit_code() == 0 else {
    fail("pre-existing container was disturbed by the refused run")
  }
  println("Docker lifecycle E2E PASS")
}
