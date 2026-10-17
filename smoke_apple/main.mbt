///|
/// Apple Container CLI E2E. Run only on a physical macOS 26 Apple Silicon host.
async fn main {
  let name = "container-mbt-apple-\{@async.now()}"
  let image = @container.GenericImage::new("alpine", "3.20")
    .with_container_name(name)
    .with_cmd(["sh", "-c", "echo moonbit-apple-ready; sleep 120"])
    .with_mapped_port(18080, @container.ContainerPort::tcp(80))
    .with_wait_for(@container.WaitFor::message_on_stdout("moonbit-apple-ready"))
    .with_startup_timeout(60000)
  let container = image.start(@container.AppleContainer)
  // Why not retain a newly created VM after a failed assertion.
  errdefer (container.rm() catch { _ => () })
  // What: the CLI returns the fixed port rather than a fabricated dynamic port.
  guard container.get_host_port_ipv4(@container.ContainerPort::tcp(80)) == 18080 else {
    fail("Apple Container reported an unexpected fixed host port")
  }
  let response = container.exec(["sh", "-c", "printf moonbit-apple-e2e"])
  guard response.exit_code() == 0 && response.stdout() == "moonbit-apple-e2e" else {
    fail("Apple Container exec failed: \{response.stderr()}")
  }
  let logs = container.logs()
  guard logs.exit_code() == 0 && logs.stdout().contains("moonbit-apple-ready") else {
    fail("Apple Container logs did not contain the startup marker")
  }
  container.stop()
  container.rm()
  let probe = @shell.Cmd("container", ["inspect", name]).output(
    timeout_ms=15000,
    max_output_bytes=1048576,
  )
  guard probe.exit_code() != 0 else {
    fail("Apple Container still exists after removal")
  }
  println("Apple Container lifecycle E2E PASS")
}
