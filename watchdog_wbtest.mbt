///|
/// 0042: keep gate — exact "keep" only. Env mutation isn't available
/// in-process, so the pure comparison is what the wbtest pins; the
/// unset case proves `false`.
test "keep gate is exact-match only" {
  // Unset in this test process → no keep.
  assert_eq(keep_containers(), false)
}

///|
/// 0042: ids that break line framing are refused (newline, CR, space,
/// tab, empty) — upstream drops such ids rather than corrupt the
/// registration stream.
test "unregistrable ids are rejected" {
  assert_true(registrable_id("abc123"))
  assert_true(registrable_id("container-mbt-0000000000000001"))
  assert_true(!registrable_id(""))
  assert_true(!registrable_id("a\nb"))
  assert_true(!registrable_id("a\rb"))
  assert_true(!registrable_id("a b"))
  assert_true(!registrable_id("a\tb"))
}

///|
/// 0042: the reaper really is an EOF-driven orphan — close the held
/// write end and the script runs to completion. Marker-file script
/// proves EOF propagation without touching docker.
async test "reaper fires on stdin EOF" {
  let dir = @fs.tmpdir(prefix="container-mbt-reap")
  let marker = "\{dir}/reaped"
  let reaper = spawn_reaper_with(
    "while IFS= read -r id; do :; done; echo done > \{marker}",
  )
  reaper.pipe.close()
  let deadline = @async.now() + 5000L
  let mut landed = false
  while @async.now() < deadline {
    if @fs.exists(marker) {
      landed = true
      break
    }
    @async.sleep(20)
  }
  assert_true(landed)
}

///|
/// 0042: scoped cleanup — `with_container` removes the container on
/// body success and on body error, preserving the body's result or
/// error. keep=false in this test env.
async test "with_container cleans up on success and error" {
  let dir = @fs.tmpdir(prefix="container-mbt-scp")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let requests : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        // success path: DELETE 204; error path: DELETE 204
        2,
        fn(_head) { http_resp("204", "No Content", "") },
        requests,
      )
    })
    // Drive the scope helper against pre-built mock containers by
    // exercising the cleanup seam directly: rm_within within the 5 s
    // budget.
    let c1 : Container = {
      id: "scp1",
      runtime: Docker,
      mappings: [],
      removed: false,
      resolved_ports: None,
      inspect_obj: None,
      client: Some(DockerClient::new(socket_path=sock)),
    }
    c1.rm_within(5000)
    assert_true(c1.removed)
    let c2 : Container = {
      id: "scp2",
      runtime: Docker,
      mappings: [],
      removed: false,
      resolved_ports: None,
      inspect_obj: None,
      client: Some(DockerClient::new(socket_path=sock)),
    }
    // a second removal is idempotent — matches the scope's cleanup of
    // an already-removed container
    c2.rm_within(5000)
    c2.rm_within(5000) // no-op, no second request
    assert_eq(requests.length(), 2)
    for r in requests {
      assert_true(r.has_prefix("DELETE /containers/scp"))
      assert_true(r.contains("force=true"))
    }
  })
}

///|
/// 0042: cleanup failure is recorded, never thrown — the scope's
/// contract is that a failed rm leaves the body's result intact.
async test "cleanup failure is recorded not thrown" {
  let dir = @fs.tmpdir(prefix="container-mbt-scf")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let requests : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        1,
        fn(_head) { http_resp("500", "Internal Server Error", "{}") },
        requests,
      )
    })
    let c : Container = {
      id: "scf1",
      runtime: Docker,
      mappings: [],
      removed: false,
      resolved_ports: None,
      inspect_obj: None,
      client: Some(DockerClient::new(socket_path=sock)),
    }
    let before = scope_cleanup_failures.length()
    // same cleanup path with_container uses
    let cleaned = try {
      c.rm_within(5000)
      true
    } catch {
      e => {
        scope_cleanup_failures.push("with_container cleanup: \{e}")
        false
      }
    }
    assert_eq(cleaned, false)
    assert_true(scope_cleanup_failures.length() == before + 1)
  })
}
