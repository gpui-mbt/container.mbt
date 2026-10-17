///|
/// 0037: builders retain values; `to_docker_json` emits the upstream
/// fragment (durations in nanoseconds); an all-default healthcheck
/// stays unwired.
test "healthcheck builders and docker json fragment" {
  let hc = Healthcheck::cmd_shell("curl -fsS localhost/health")
    .with_interval(30000)
    .with_timeout(5000)
    .with_retries(5)
    .with_start_period(10000)
    .with_start_interval(2000)
  let j = hc.to_docker_json().unwrap()
  assert_true(
    j.contains("\"Test\":[\"CMD-SHELL\",\"curl -fsS localhost/health\"]"),
  )
  assert_true(j.contains("\"Interval\":30000000000"))
  assert_true(j.contains("\"Timeout\":5000000000"))
  assert_true(j.contains("\"StartPeriod\":10000000000"))
  assert_true(j.contains("\"StartInterval\":2000000000"))
  assert_true(j.contains("\"Retries\":5"))
  let cmd = Healthcheck::cmd(["/bin/probe", "--deep"]).to_docker_json().unwrap()
  assert_true(cmd.contains("\"Test\":[\"CMD\",\"/bin/probe\",\"--deep\"]"))
  assert_true(
    Healthcheck::none()
    .to_docker_json()
    .unwrap_or("")
    .contains("\"Test\":[\"NONE\"]"),
  )
  // Empty must not wire anything (upstream to_docker_json -> None).
  let empty : Healthcheck = {
    test_args: [],
    interval_ms: None,
    timeout_ms: None,
    retries: None,
    start_period_ms: None,
    start_interval_ms: None,
  }
  assert_true(empty.to_docker_json() is None)
}

///|
/// 0037: the create request body carries `Healthcheck` only when a
/// non-empty check is attached.
test "create request serializes healthcheck" {
  let image = GenericImage::new("repo/health", "1.0")
  ignore(image.with_healthcheck(Healthcheck::cmd_shell("true")))
  let wired = create_request(image).to_json()
  assert_true(
    wired.contains("\"Healthcheck\":{\"Test\":[\"CMD-SHELL\",\"true\"]}"),
  )
  let image2 = GenericImage::new("repo/plain", "1.0")
  let no_key = create_request(image2).to_json()
  assert_true(!no_key.contains("\"Healthcheck\""))
}

///|
/// Build a `Container` whose ops route through the mock engine socket.
fn mock_client_container(sock : String) -> Container {
  {
    id: "hc1",
    runtime: Docker,
    mappings: [],
    removed: false,
    resolved_ports: None,
    inspect_obj: None,
    client: Some(DockerClient::new(socket_path=sock)),
  }
}

///|
/// Scripted inspect bodies for the mock engine.
fn inspect_body(running : Bool, health : String?) -> String {
  let mut b = "{\"State\":{\"Running\":\{running}"
  match health {
    Some(h) => b = "\{b},\"Health\":{\"Status\":\"\{h}\"}"
    None => ()
  }
  "\{b}}}"
}

///|
/// 0037: starting → starting → healthy completes; the wire polls
/// `GET /containers/{id}/json`.
async test "health poll waits through starting to healthy" {
  let dir = @fs.tmpdir(prefix="container-mbt-hc")
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
        inspect_body(true, Some("starting")),
        inspect_body(true, Some("starting")),
        inspect_body(true, Some("healthy")),
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
    mock_client_container(sock).healthcheck_wait_until(@async.now() + 20000)
    assert_eq(requests.length(), 3)
    for r in requests {
      assert_eq(r, "GET /containers/hc1/json HTTP/1.1")
    }
  })
}

///|
/// 0037: `unhealthy` fails immediately — one poll, not until deadline.
async test "unhealthy fails fast" {
  let dir = @fs.tmpdir(prefix="container-mbt-hcu")
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
        fn(_head) { http_200(inspect_body(true, Some("unhealthy"))) },
        requests,
      )
    })
    let r = try {
      mock_client_container(sock).healthcheck_wait_until(@async.now() + 60000)
      "waited"
    } catch {
      e => if "\{e}".contains("unhealthy") { "unhealthy" } else { "other:\{e}" }
    }
    assert_eq(r, "unhealthy")
    assert_eq(requests.length(), 1)
  })
}

///|
/// 0037: running observed + no Health object → not-configured error;
/// before Running is observed the wait continues (starting → running
/// without health → error).
async test "missing health fails only after running is observed" {
  let dir = @fs.tmpdir(prefix="container-mbt-hcm")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let requests : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      // First poll: still starting (no Health, not Running) → keep
      // waiting; second: running without Health → fail.
      let bodies = [inspect_body(false, None), inspect_body(true, None)]
      let mut i = 0
      serve_mock_engine(
        listen_fd,
        2,
        fn(_head) {
          let b = bodies[i]
          i = i + 1
          http_200(b)
        },
        requests,
      )
    })
    let r = try {
      mock_client_container(sock).healthcheck_wait_until(@async.now() + 20000)
      "waited"
    } catch {
      e =>
        if "\{e}".contains("no healthcheck configured") {
          "not-configured"
        } else {
          "other:\{e}"
        }
    }
    assert_eq(r, "not-configured")
    assert_eq(requests.length(), 2)
  })
}

///|
/// 0037: a container without a direct client reports the CLI-adapter
/// refusal instead of polling.
async test "cli container rejects healthcheck wait" {
  let bare : Container = {
    id: "t",
    runtime: Docker,
    mappings: [],
    removed: false,
    resolved_ports: None,
    inspect_obj: None,
    client: None,
  }
  let r = try {
    bare.healthcheck_wait_until(@async.now() + 5000)
    "waited"
  } catch {
    e =>
      if "\{e}".contains("CLI adapters") {
        "cli-refusal"
      } else {
        "other:\{e}"
      }
  }
  assert_eq(r, "cli-refusal")
}

///|
/// 0037: `with_healthcheck` marks `HealthcheckWait` used — the CLI
/// adapter preflight rejects before any side effect (0004 posture).
test "healthcheck config maps to HealthcheckWait capability" {
  let image = GenericImage::new("repo/hc", "1")
  ignore(image.with_healthcheck(Healthcheck::cmd_shell("true")))
  assert_true(settings_in_use(image).iter().any(fn(s) { s is HealthcheckWait }))
  let r = try {
    preflight(CliDocker, image)
    "supported"
  } catch {
    e => if "\{e}".contains("healthcheck") { "rejected" } else { "other:\{e}" }
  }
  assert_eq(r, "rejected")
  // Direct adapter supports both the config and the wait.
  assert_true(capability(DirectDocker, HealthcheckWait) is Supported)
  assert_true(capability(CliApple, HealthcheckWait) is NotYetImplemented(_))
}
