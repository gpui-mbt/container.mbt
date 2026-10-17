///|
/// 0004: a rejected setting must fail inside the pure preflight, long before
/// a runtime process could be spawned — so `build_run_args` alone proves it.
fn rejected(runtime : Runtime, image : GenericImage) -> String {
  try {
    ignore(
      build_run_args(runtime, image, attempt={
        name: "preflight-check",
        run_id: "preflight-run",
        user_named: true,
      }),
    )
    ""
  } catch {
    Failure::Failure(message) => message
    _ => "non-failure error"
  }
}

///|
/// 0004: SCTP publishing is rejected on Apple with the upstream wording.
test "Apple rejects SCTP port publication" {
  let image = GenericImage::new("redis", "latest").with_mapped_port(
    16379,
    ContainerPort::sctp(80),
  )
  let message = rejected(AppleContainer, image)
  assert_true(message.contains("SCTP"))
  // The same request is applied on Docker.
  let image_tcp = GenericImage::new("redis", "latest").with_mapped_port(
    16379,
    ContainerPort::sctp(80),
  )
  let args = build_run_args(Docker, image_tcp, attempt={
    name: "sctp-ok",
    run_id: "rid",
    user_named: true,
  })
  assert_true(args.join(" ").contains("--publish 16379:80/sctp"))
}

///|
/// 0004: automatic host-port assignment stays an explicit rejection on Apple.
test "Apple rejects an ephemeral host port" {
  let image = GenericImage::new("nginx", "latest").with_exposed_port(
    ContainerPort::tcp(80),
  )
  let message = rejected(AppleContainer, image)
  assert_true(message.contains("host port"))
}

///|
/// 0004: duplicate container ports must not silently overwrite each other.
test "duplicate container ports are rejected on both runtimes" {
  let image = GenericImage::new("nginx", "latest")
    .with_mapped_port(18080, ContainerPort::tcp(80))
    .with_mapped_port(18081, ContainerPort::tcp(80))
  assert_true(
    rejected(Docker, image).contains("duplicate published container port"),
  )
  assert_true(
    rejected(AppleContainer, image).contains(
      "duplicate published container port",
    ),
  )
}

///|
/// 0004: two container ports sharing one host port conflict identically.
test "duplicate host ports are rejected on both runtimes" {
  let image = GenericImage::new("nginx", "latest")
    .with_mapped_port(18080, ContainerPort::tcp(80))
    .with_mapped_port(18080, ContainerPort::tcp(81))
  assert_true(rejected(Docker, image).contains("duplicate published host port"))
  // The same host port may serve TCP and UDP container ports.
  let split = GenericImage::new("nginx", "latest")
    .with_mapped_port(15353, ContainerPort::tcp(53))
    .with_mapped_port(15353, ContainerPort::udp(53))
  let args = build_run_args(Docker, split, attempt={
    name: "split-proto",
    run_id: "rid",
    user_named: true,
  })
  assert_true(args.join(" ").contains("15353:53/tcp"))
  assert_true(args.join(" ").contains("15353:53/udp"))
}

///|
/// 0004: settings not yet verified on Apple Container are refused up front.
test "unverified Apple settings are refused before spawning" {
  let cases : Array[(GenericImage, String)] = [
    (GenericImage::new("a", "1").with_network("bridge"), "--network"),
    (GenericImage::new("a", "1").with_platform("linux/arm64"), "--platform"),
    (GenericImage::new("a", "1").with_user("nobody"), "--user"),
    (
      GenericImage::new("a", "1").with_mount(Mount::bind_mount("/tmp", "/tmp")),
      "--mount",
    ),
    (GenericImage::new("a", "1").with_readonly_rootfs(true), "--read-only"),
  ]
  for (image, setting) in cases {
    let message = rejected(AppleContainer, image)
    assert_true(
      message.contains(setting) && message.contains("Apple Container"),
    )
  }
  // The same settings are applied on Docker, which supports them.
  let image = GenericImage::new("a", "1")
    .with_network("bridge")
    .with_platform("linux/arm64")
    .with_user("nobody")
    .with_readonly_rootfs(true)
    .with_mount(Mount::tmpfs_mount("/scratch"))
  let args = build_run_args(Docker, image, attempt={
    name: "docker-apply",
    run_id: "rid",
    user_named: true,
  })
  let joined = args.join(" ")
  assert_true(joined.contains("--network bridge"))
  assert_true(joined.contains("--platform linux/arm64"))
  assert_true(joined.contains("--user nobody"))
  assert_true(joined.contains("--read-only"))
  assert_true(joined.contains("--mount type=tmpfs,target=/scratch"))
}

///|
/// 0004: unsupported readiness conditions are rejected on both runtimes.
test "unimplemented readiness kinds are rejected before spawning" {
  for runtime in [Docker, AppleContainer] {
    let image = GenericImage::new("a", "1").with_wait_for(
      WaitFor::healthcheck(),
    )
    assert_true(rejected(runtime, image).contains("healthcheck"))
    let image_exit = GenericImage::new("a", "1").with_wait_for(
      WaitFor::when_exited(),
    )
    assert_true(rejected(runtime, image_exit).contains("exit"))
  }
}

///|
/// 0004: the golden argv for the working configuration must not drift.
test "accepted request keeps the smoke argv shape" {
  let image = GenericImage::new("alpine", "3.20")
    .with_container_name("golden")
    .with_cmd(["tail", "-f", "/dev/null"])
    .with_mapped_port(18080, ContainerPort::tcp(80))
    .with_wait_for(WaitFor::message_on_stdout("ready"))
  let args = build_run_args(Docker, image, attempt={
    name: "golden",
    run_id: "golden-run",
    user_named: true,
  })
  assert_eq(args[0], "run")
  assert_eq(args[1], "--detach")
  let joined = args.join(" ")
  assert_true(joined.contains("--name golden"))
  assert_true(joined.contains("--label container-mbt.owned=golden-run"))
  assert_true(joined.contains("--publish 18080:80/tcp"))
  assert_eq(args[args.length() - 4], "alpine:3.20")
}

///|
/// 0019: every matrix cell is decided — Supported, Rejected, or
/// NotYetImplemented — nothing is left implicit.
test "capability matrix covers every adapter and setting" {
  let adapters = [DirectDocker, DirectXpc, CliDocker, CliApple]
  let settings = [
    Command,
    Entrypoint,
    ContainerName,
    EnvVars,
    Labels,
    Mappings,
    DynamicPort,
    SctpPort,
    Mounts,
    ReadyWait,
    HealthcheckWait,
    ExitWait,
    WorkingDir,
    User,
    Network,
    Platform,
    ReadonlyRootfs,
    StartupTimeout,
  ]
  for adapter in adapters {
    for setting in settings {
      // Merely evaluating the cell must not raise.
      ignore(capability(adapter, setting))
    }
  }
  // Spotlight cells that pin the 0019 contract.
  assert_true(capability(CliApple, DynamicPort) is Rejected(_))
  assert_true(capability(CliApple, SctpPort) is Rejected(_))
  assert_true(capability(CliDocker, DynamicPort) is Supported)
  assert_true(capability(DirectDocker, DynamicPort) is Supported)
  assert_true(capability(DirectDocker, Mounts) is Supported)
  assert_true(capability(DirectXpc, Command) is NotYetImplemented(_))
  assert_true(capability(CliDocker, HealthcheckWait) is NotYetImplemented(_))
  assert_true(capability(CliApple, ExitWait) is NotYetImplemented(_))
}

///|
/// 0019: adapter resolution — start() targets direct adapters,
/// start_cli() the CLI adapters; there is no implicit fallback.
test "adapter resolution never falls back to CLI" {
  assert_true(adapter_for(Docker) is DirectDocker)
  assert_true(adapter_for(AppleContainer) is DirectXpc)
  assert_true(cli_adapter_for(Docker) is CliDocker)
  assert_true(cli_adapter_for(AppleContainer) is CliApple)
}

///|
/// 0019: a NYI setting fails before the adapter is even contacted.
/// start(Docker) with a healthcheck wait must raise the matrix error —
/// not a transport error — proving zero requests left the client.
async test "matrix rejection precedes any socket traffic" {
  let image = GenericImage::new("a", "1").with_wait_for(WaitFor::healthcheck())
  try image.start(Docker) catch {
    Failure::Failure(msg) => assert_true(msg.contains("healthcheck"))
    err => fail("expected matrix rejection, got \{err}")
  } noraise {
    _ => fail("expected failure")
  }
  // start(AppleContainer) selects DirectXpc — every setting NYI, and
  // even a bare image fails at the adapter dispatch, not the CLI.
  let bare = GenericImage::new("a", "1")
  try bare.start(AppleContainer) catch {
    Failure::Failure(msg) => assert_true(msg.contains("XPC"))
    err => fail("expected XPC NYI error, got \{err}")
  } noraise {
    _ => fail("expected failure")
  }
}

///|
/// 0019: start(Docker) with no daemon must surface the direct
/// transport's own error — never a silent CLI fallback.
async test "missing socket propagates the direct-transport error" {
  let image = GenericImage::new("a", "1")
  try image.start(Docker) catch {
    EngineError::TransportError(..) | EngineError::DeadlineExceeded(..) => ()
    err => fail("expected a direct transport failure, got \{err}")
  } noraise {
    _ => fail("expected failure without a daemon")
  }
}

///|
/// 0019: full direct-path lifecycle against a mock daemon — resolve
/// 404 → pull → resolve 200 → create → start → inspect ports → stop →
/// rm, all on the socket, zero CLI processes (none exist in this
/// environment, so any spawn would have failed the test).
async test "direct start routes the whole lifecycle over the socket" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let captured : Array[String] = []
  let wire : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        8,
        fn(request) {
          wire.push(request)
          if request.has_prefix("GET /images/") {
            if wire.length() == 1 {
              http_resp("404", "Not Found", "{\"message\":\"no such image\"}")
            } else {
              http_200("{}")
            }
          } else if request.has_prefix("POST /images/create") {
            http_200("{\"status\":\"ok\"}")
          } else if request.has_prefix("POST /containers/create") {
            http_resp("201", "Created", "{\"Id\":\"abc123\"}")
          } else if request.has_prefix("GET /containers/abc123/json") {
            http_200(
              "{\"State\":{\"Running\":true},\"NetworkSettings\":{\"Ports\":{\"80/tcp\":[{\"HostIp\":\"0.0.0.0\",\"HostPort\":\"49155\"}]}}}",
            )
          } else {
            http_resp("204", "No Content", "")
          }
        },
        captured,
      )
    })
    let client = DockerClient::new(socket_path=sock)
    let image = GenericImage::new("alpine", "3.20").with_exposed_port(
      ContainerPort::tcp(80),
    )
    let container = image.start_with_client(client)
    assert_eq(container.id(), "abc123")
    // Dynamic port resolves through the API inspect, not the CLI.
    assert_eq(container.get_host_port_ipv4(ContainerPort::tcp(80)), 49155)
    container.stop()
    container.rm()
  })
  // The wire saw: resolve, pull, resolve, create, start, inspect, stop,
  // rm — exactly 8 requests, all over the socket.
  assert_eq(wire.length(), 8)
  assert_true(
    wire[0].has_prefix("GET /images/alpine%3A3.20/json") ||
    wire[0].has_prefix("GET /images/alpine:3.20/json"),
  )
  assert_true(wire[3].has_prefix("POST /containers/create"))
  assert_true(wire[4].has_prefix("POST /containers/abc123/start"))
  assert_true(wire[6].has_prefix("POST /containers/abc123/stop"))
  assert_true(wire[7].has_prefix("DELETE /containers/abc123"))
}
