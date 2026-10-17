///|
/// Linux direct-Engine-API E2E (issue 0020): pull → create → start →
/// wait → exec → logs → inspect → stop → rm → inspect, all over the
/// Unix socket. CI runs this binary with `docker` removed from PATH —
/// any CLI spawn would fail the run.

///|
let evidence : Ref[Int32] = { val: 0, }

///|
fn step(name : String, detail : String, started : Int64) -> Unit {
  evidence.val += 1
  let ms = @async.now() - started
  println("[e2e:\{evidence.val}] \{name}: \{detail} (\{ms}ms)")
}

///|
async fn main {
  let client = @container.DockerClient::new()
  let t0 = @async.now()
  let daemon = client.preflight()
  step(
    "preflight",
    "daemon reachable over /var/run/docker.sock (api \{daemon.api_version})",
    t0,
  )
  let run_id = "\{@async.now()}"
  let name = "container-mbt-linux-e2e-\{run_id}"
  let image = @container.GenericImage::new("alpine", "3.20")
    .with_container_name(name)
    .with_cmd([
      "sh", "-c", "echo container-mbt-linux-ready && tail -f /dev/null",
    ])
    .with_mapped_port(18080, @container.ContainerPort::tcp(80))
    .with_wait_for(
      @container.WaitFor::message_on_stdout("container-mbt-linux-ready"),
    )
    .with_startup_timeout(120000)
  // pull → create → start → wait; identity label is applied by start.
  let t = @async.now()
  let container = image.start(@container.Docker)
  step("pull+create+start+wait", "id=\{container.id()} name=\{name}", t)
  // Best-effort removal of exactly this run's container; never masks
  // the original error and never touches foreign containers.
  errdefer (try client.remove_container(container.id(), force=true) catch {
    _ => ()
  } noraise {
    _ => ()
  })
  // exec: stdout / stderr / exit code agreement.
  let t = @async.now()
  let ok = container.exec(["sh", "-c", "printf moonbit-direct"])
  guard ok.exit_code() == 0 && ok.stdout() == "moonbit-direct" else {
    fail(
      "exec mismatch: code=\{ok.exit_code()} out=\{ok.stdout()} err=\{ok.stderr()}",
    )
  }
  step("exec", "exit=0 stdout=moonbit-direct", t)
  // exec non-zero exit is recorded, not raised away.
  let t = @async.now()
  let bad = container.exec(["sh", "-c", "echo e2e-err >&2; exit 7"])
  guard bad.exit_code() == 7 && bad.stderr().contains("e2e-err") else {
    fail("non-zero exec not reported: code=\{bad.exit_code()}")
  }
  step("exec-nonzero", "exit=7 stderr=e2e-err", t)
  // logs: bounded retrieval contains the readiness marker.
  let t = @async.now()
  let logs = container.logs()
  guard logs.stdout().contains("container-mbt-linux-ready") else {
    fail("logs missing readiness marker")
  }
  step("logs", "stdout contains readiness marker", t)
  // inspect: running state and the fixed published port agree.
  let t = @async.now()
  let inspected = client.inspect_container(container.id())
  guard inspected.running else { fail("container not running per inspect") }
  let port = container.get_host_port_ipv4(@container.ContainerPort::tcp(80))
  guard port == 18080 else { fail("published port \{port} != 18080") }
  step("inspect", "running=true published=18080:80/tcp", t)
  // stop → rm → inspect proves not-found.
  let t = @async.now()
  container.stop()
  step("stop", "id=\{container.id()}", t)
  let t = @async.now()
  container.rm()
  step("rm", "id=\{container.id()}", t)
  let gone = try {
    ignore(client.inspect_container(container.id()))
    false
  } catch {
    @container.EngineError::ContainerNotFound(..) => true
    err => fail("unexpected inspect error after rm: \{err}")
  }
  guard gone else { fail("container still inspectable after rm") }
  step("inspect-after-rm", "not found", @async.now())
  // Failure injection: an unreachable readiness condition must roll
  // back the created container inside the startup deadline.
  let failing = @container.GenericImage::new("alpine", "3.20")
    .with_container_name("container-mbt-linux-e2e-bad-\{run_id}")
    .with_cmd(["tail", "-f", "/dev/null"])
    .with_wait_for(
      @container.WaitFor::message_on_stdout("never-printed-container-mbt"),
    )
    .with_startup_timeout(3000)
  let t = @async.now()
  let rejected = try {
    let unexpected = failing.start(@container.Docker)
    unexpected.rm()
    false
  } catch {
    _ => true
  }
  guard rejected else { fail("readiness failure did not reject start") }
  let leaked = try {
    ignore(client.inspect_container("container-mbt-linux-e2e-bad-\{run_id}"))
    true
  } catch {
    @container.EngineError::ContainerNotFound(..) => false
    err => fail("unexpected inspect error for failed run: \{err}")
  }
  guard !leaked else {
    ignore(
      client.remove_container(
        "container-mbt-linux-e2e-bad-\{run_id}",
        force=true,
      ) catch {
        _ => ()
      },
    )
    fail("readiness failure left a container behind")
  }
  step("readiness-rollback", "failed start left no container", t)
  println("Linux direct-API E2E PASS (\{evidence.val} steps)")
}
