///|
/// 0041: grace normalization — None and negative → 30 s default;
/// non-negative used verbatim. (Upstream's macOS i32::MAX conversion
/// is deliberately NOT adopted — a CLI adapter could block ~24 h.)
test "normalize_stop_grace branches" {
  assert_eq(normalize_stop_grace(None), 30)
  assert_eq(normalize_stop_grace(Some(-1)), 30)
  assert_eq(normalize_stop_grace(Some(-999)), 30)
  assert_eq(normalize_stop_grace(Some(0)), 0)
  assert_eq(normalize_stop_grace(Some(1)), 1)
  assert_eq(normalize_stop_grace(Some(3600)), 3600)
}

///|
/// 0041: argv assembly — Docker `-t`, Apple `--time`, and the `0` →
/// kill switch.
test "stop args per runtime and grace" {
  assert_eq(build_stop_args(Docker, "c1", None), ["stop", "-t", "30", "c1"])
  assert_eq(build_stop_args(AppleContainer, "c1", Some(7)), [
    "stop", "--time", "7", "c1",
  ])
  assert_eq(build_stop_args(Docker, "c1", Some(0)), ["kill", "c1"])
  assert_eq(build_stop_args(AppleContainer, "c1", Some(0)), ["kill", "c1"])
  assert_eq(build_stop_args(Docker, "c1", Some(-5)), ["stop", "-t", "30", "c1"])
}

///|
/// 0041: direct-path stop carries `?t=` — 30 default, explicit value,
/// and `t=0` is the daemon's own immediate-kill parameter.
async test "direct stop carries grace on the wire" {
  let dir = @fs.tmpdir(prefix="container-mbt-stop")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let requests : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_mock_engine(listen_fd, 3, fn(_head) { http_200("") }, requests)
    })
    let client = DockerClient::new(socket_path=sock)
    client.stop_container("c1")
    client.stop_container("c1", timeout_seconds=10)
    client.stop_container("c1", timeout_seconds=0)
    assert_eq(requests, [
      "POST /containers/c1/stop?t=30 HTTP/1.1", "POST /containers/c1/stop?t=10 HTTP/1.1",
      "POST /containers/c1/stop?t=0 HTTP/1.1",
    ])
  })
}

///|
/// 0041: `exit_code()` polls until `Running` settles then returns the
/// code; never cached, so a second call re-inspects.
async test "exit_code polls until settled and never caches" {
  let dir = @fs.tmpdir(prefix="container-mbt-exc")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let requests : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      let bodies = [
        // running, no exit code yet → keep polling
        "{\"State\":{\"Running\":true}}",
        // settled
         "{\"State\":{\"Running\":false,\"ExitCode\":3}}",
        // second call re-inspects — same answer, new request
         "{\"State\":{\"Running\":false,\"ExitCode\":3}}",
      ]
      let mut i = 0
      serve_mock_engine(
        listen_fd,
        3,
        fn(_head) {
          let b = bodies[i]
          i = i + 1
          http_200(b)
        },
        requests,
      )
    })
    let c : Container = {
      id: "ec1",
      runtime: Docker,
      mappings: [],
      removed: false,
      resolved_ports: None,
      inspect_obj: None,
      client: Some(DockerClient::new(socket_path=sock)),
    }
    assert_eq(c.exit_code(), Some(3))
    assert_eq(c.exit_code(), Some(3))
    assert_eq(requests.length(), 3)
  })
}

///|
/// 0041: a missing container or one without a recorded code yields
/// `None`, never a fabricated 0.
async test "exit_code is None when unobtainable" {
  let dir = @fs.tmpdir(prefix="container-mbt-exn")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let requests : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      let bodies = [
        "{\"State\":{\"Running\":false}}", // no ExitCode
      ]
      let mut i = 0
      serve_mock_engine(
        listen_fd,
        1,
        fn(_head) {
          let b = bodies[i]
          i = i + 1
          http_200(b)
        },
        requests,
      )
    })
    let c : Container = {
      id: "ec2",
      runtime: Docker,
      mappings: [],
      removed: false,
      resolved_ports: None,
      inspect_obj: None,
      client: Some(DockerClient::new(socket_path=sock)),
    }
    assert_eq(c.exit_code(), None)
  })
}
