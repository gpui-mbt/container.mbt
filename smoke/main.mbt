///|
/// Exercise the actual Docker Engine through the native CLI adapter.
async fn main raise {
  let image = @container.GenericImage::new("alpine", "3.20")
    .with_cmd(["tail", "-f", "/dev/null"])
  let container = image.start(@container.Docker)
  // Why not strand containers if a later assertion fails or the task is cancelled.
  errdefer {
    container.rm() catch { _ => () }
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
  println("Docker lifecycle E2E PASS")
}
