///|
/// 0021: owner-id format pins down what a label value may claim — only
/// p<pid>t<16hex> is ever looked up as a lock file.
test "owner id format is enforced" {
  assert_true(valid_owner_id("p1234-t0123456789abcdef"))
  assert_true(!valid_owner_id(""))
  assert_true(!valid_owner_id("p-t0123456789abcdef"))
  assert_true(!valid_owner_id("p12x4-t0123456789abcdef"))
  assert_true(!valid_owner_id("p1234-t0123456789abcde"))
  assert_true(!valid_owner_id("p1234-t0123456789abcdeg"))
  assert_true(!valid_owner_id("../etc/passwd"))
  assert_true(!valid_owner_id("p1234_t0123456789abcdef"))
}

///|
/// 0021: a live owner is detected through its held lock; a dead owner
/// (lock acquirable) is not.
async test "owner liveness probe uses the kernel lock" {
  let dir = @fs.tmpdir(prefix="container-mbt-locks")
  let live = "p999999-t0123456789abcde0"
  let held = try_owner_lock("\{dir}/owner-\{live}.lock").unwrap()
  defer release_lock(held)
  // Same-process flock does not conflict with itself on Linux (locks
  // are per-open-file-description) — spawn a probe via a second lock
  // the test holds is enough: probe of OUR owner id must say alive.
  let own = ensure_owner_lock()
  assert_true(valid_owner_id(own))
  assert_true(owner_alive(owner_lock_dir(), own))
  // A never-held owner id reads as dead.
  let dead = "p424242-t0123456789abcde1"
  assert_true(!owner_alive(dir, dead))
  let raised = try {
    ignore(owner_alive("\{dir}/sub", dead))
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}

///|
/// 0021: recovery removes only dead-owned containers — live owners,
/// malformed labels, and label-less entries are skipped with reasons;
/// delete failures are aggregated not raised.
async test "recovery is ownership-bounded and diagnosable" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let lock_dir = @fs.tmpdir(prefix="container-mbt-locks")
  let listen_fd = unix_listen(sock)
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  // Hold a "live" owner's lock in-process so the probe sees it alive.
  let live_owner = "p7777-tabcdef0123456789"
  let live_fd = try_owner_lock("\{lock_dir}/owner-\{live_owner}.lock").unwrap()
  defer release_lock(live_fd)
  let dead_owner = "p8888-tabcdef0123456789"
  let list_body = "[{\"Id\":\"dead1\",\"Names\":[\"/orphan\"],\"Labels\":{\"container-mbt.owned\":\"\{dead_owner}\"}},{\"Id\":\"live1\",\"Names\":[\"/busy\"],\"Labels\":{\"container-mbt.owned\":\"\{live_owner}\"}},{\"Id\":\"bad1\",\"Names\":[\"/bad\"],\"Labels\":{\"container-mbt.owned\":\"garbage!!\"}},{\"Id\":\"nolabel\",\"Names\":[\"/foreign\"],\"Labels\":{}},{\"Id\":\"gone1\",\"Names\":[\"/gone\"],\"Labels\":{\"container-mbt.owned\":\"\{dead_owner}\"}},{\"Id\":\"fail1\",\"Names\":[\"/fail\"],\"Labels\":{\"container-mbt.owned\":\"\{dead_owner}\"}}]"
  let wire : Array[String] = []
  let captured : Array[String] = []
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        4,
        fn(request) {
          wire.push(request)
          if request.has_prefix("GET /containers/json") {
            http_200(list_body)
          } else if request.contains("/containers/gone1") {
            // Raced delete: already gone — counts as removed (idempotent rm).
            http_resp("404", "Not Found", "{\"message\":\"already gone\"}")
          } else if request.contains("/containers/fail1") {
            http_resp("500", "Server Error", "{\"message\":\"daemon stuck\"}")
          } else {
            http_resp("204", "No Content", "")
          }
        },
        captured,
      )
    })
    let client = DockerClient::new(socket_path=sock)
    // lock_dir injection points the probe at the fixture dir where
    // the live owner's lock is held by this test.
    let report = client.recover_orphaned_containers(lock_dir~)
    assert_eq(report.removed, ["dead1", "gone1"])
    assert_eq(report.failed.length(), 1)
    assert_eq(report.failed[0].0, "fail1")
    // live owner, malformed label, missing label → 3 skips.
    assert_eq(report.skipped.length(), 3)
    assert_true(report.summary().contains("removed=2"))
  })
}
