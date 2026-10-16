///|
/// Exercise the actual Docker Engine through the native CLI adapter.
async fn main raise {
  let image = @container.GenericImage::new("alpine", "3.20")
    .with_cmd(["tail", "-f", "/dev/null"])
    .with_exposed_port(@container.ContainerPort::tcp(80))
  let container = image.start(@container.Docker)
  // Why not strand containers if a later assertion fails or the task is cancelled.
  errdefer {
    container.rm() catch { _ => () }
  }
  // What: mutations after start must not change the reported host mappings.
  ignore(image.with_mapped_port(18081, @container.ContainerPort::tcp(81)))
  let leaked = image.mappings()
  leaked.push(@container.PortMapping::new(18082, @container.ContainerPort::tcp(82)))
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
  guard logs.exit_code() == 0 else {
    fail("docker logs returned nonzero exit")
  }
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
  guard rejected else { fail("startup deadline failed to reject slow readiness") }
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
  println("Docker lifecycle E2E PASS")
}
