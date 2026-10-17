///|
test "container name boundaries match Apple/Docker validation" {
  assert_true(valid_container_name("ab"))
  assert_true(valid_container_name("a.b_c-d"))
  assert_true(valid_container_name("a" + "b".repeat(62)))
  assert_true(!valid_container_name("a"))
  assert_true(!valid_container_name("a" + "b".repeat(63)))
  assert_true(!valid_container_name("-bad"))
  assert_true(!valid_container_name("bad/name"))
  assert_true(!valid_container_name("bad name"))
  assert_true(!valid_container_name("bad\nname"))
}

///|
test "argv values are never shell-split" {
  let attempt : RunAttempt = {
    name: "argv-test",
    run_id: "rid",
    user_named: true,
    owner_id: "p1-t0000000000000001",
  }
  let image = GenericImage::new("alpine", "3.20")
    .with_cmd(["sh", "-c", "echo $(id) `whoami`; echo | cat"])
  let args = build_run_args(Docker, image, attempt~)
  let joined = args.join("\u{0}")
  assert_true(joined.contains("echo $(id) `whoami`; echo | cat"))
  // The injected value remains one argv element; it was not split.
  assert_false(args.any(fn(a) { a == "$(id)" }))
}

///|
test "wait durations reject negative and overflowing values" {
  try {
    ignore(WaitFor::seconds(-1))
    fail("negative duration was accepted")
  } catch {
    _ => ()
  }
  try {
    ignore(WaitFor::seconds(3000000))
    fail("overflowing duration was accepted")
  } catch {
    _ => ()
  }
  match WaitFor::seconds(1) {
    Millis(ms) => assert_eq(ms, 1000)
    _ => fail("seconds must become millis")
  }
}

///|
test "env and label keys reject control characters" {
  let image = GenericImage::new("a", "1").with_env_var("A\u{0}B", "x")
  try {
    validate_image_request(image)
    fail("NUL env key was accepted")
  } catch {
    _ => ()
  }
  let label = GenericImage::new("a", "1").with_label("A\nB", "x")
  try {
    validate_image_request(label)
    fail("newline label key was accepted")
  } catch {
    _ => ()
  }
}

///|
test "port constructors reject out-of-range values" {
  try {
    ignore(ContainerPort::new(0, Tcp))
    fail("port 0 was accepted")
  } catch {
    _ => ()
  }
  try {
    ignore(ContainerPort::new(65536, Tcp))
    fail("port 65536 was accepted")
  } catch {
    _ => ()
  }
  try {
    ignore(PortMapping::new(-1, ContainerPort::tcp(80)))
    fail("negative host port was accepted")
  } catch {
    _ => ()
  }
}
