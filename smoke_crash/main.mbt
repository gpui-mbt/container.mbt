///|
/// Crash-injection fixture for 0021: start a label-owned container via
/// the direct path, print its id, then wait until killed. The harness
/// SIGKILLs this process — errdefer never runs — so the container is
/// left for the next run's `recover_orphaned_containers` to collect.
async fn main {
  let image = @container.GenericImage::new("alpine", "3.20")
    .with_container_name("container-mbt-crash-\{@async.now()}")
    .with_cmd(["tail", "-f", "/dev/null"])
  let container = image.start(@container.Docker)
  println("[crash] started \{container.id()}, awaiting SIGKILL")
  while true {
    @async.sleep(60000)
  }
}
