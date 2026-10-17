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
