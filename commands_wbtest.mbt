///|
test "Docker run command captures an Alpine test fixture" {
  let image = GenericImage::new("alpine", "3.20")
    .with_container_name("test-container")
    .with_cmd(["tail", "-f", "/dev/null"])
    .with_env_var("A", "one")
    .with_env_var("A", "two")
    .with_mapped_port(18080, ContainerPort::tcp(80))
    .with_wait_for(WaitFor::message_on_stdout("ready"))
  let args = build_run_args(Docker, image)
  assert_eq(args[0], "run")
  assert_eq(args[1], "--detach")
  assert_true(args.join(" ").contains("--name test-container"))
  assert_true(args.join(" ").contains("--env A=two"))
  assert_true(!args.join(" ").contains("A=one"))
  assert_true(args.join(" ").contains("--publish 18080:80/tcp"))
  assert_eq(args[args.length() - 4], "alpine:3.20")
  assert_eq(args[args.length() - 3], "tail")
}

///|
test "Apple Container CLI requires an explicit host port" {
  let explicit = GenericImage::new("nginx", "latest")
    .with_mapped_port(18080, ContainerPort::tcp(80))
  let args = build_run_args(AppleContainer, explicit)
  assert_true(args.join(" ").contains("--publish 18080:80/tcp"))
  let automatic = GenericImage::new("nginx", "latest")
    .with_exposed_port(ContainerPort::tcp(80))
  assert_true(try { ignore(build_run_args(AppleContainer, automatic)); false } catch { _ => true })
}

///|
test "duplicate port publication is rejected before launching runtime" {
  let image = GenericImage::new("nginx", "latest")
    .with_mapped_port(18080, ContainerPort::tcp(80))
    .with_mapped_port(18081, ContainerPort::tcp(80))
  assert_true(try { ignore(build_run_args(Docker, image)); false } catch { _ => true })
}

///|
test "unsupported readiness does not silently pass" {
  let image = GenericImage::new("busybox", "latest")
    .with_wait_for(Healthcheck)
  assert_true(try { ignore(build_run_args(Docker, image)); false } catch { _ => true })
}

///|
test "runtime-specific remove arguments do not target all containers" {
  assert_eq(build_remove_args(Docker, "test-container").join(" "), "rm --force test-container")
  assert_eq(
    build_remove_args(AppleContainer, "test-container").join(" "),
    "delete --force test-container",
  )
}

///|
test "mounts use separate argv elements, not a shell command" {
  let image = GenericImage::new("alpine", "latest")
    .with_mount(Mount::bind_mount("/tmp/data", "/data").with_read_only())
  let args = build_run_args(Docker, image)
  assert_true(args.join(" ").contains("--mount type=bind,target=/data,source=/tmp/data,readonly"))
}
