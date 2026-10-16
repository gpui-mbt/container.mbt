///|
test "generic image retains descriptor, command and readiness" {
  let image = GenericImage::new("alpine", "3.20")
    .with_cmd(["tail", "-f", "/dev/null"])
    .with_wait_for(WaitFor::message_on_stdout("ready"))
  assert_eq(image.descriptor(), "alpine:3.20")
  assert_eq(image.command.join(" "), "tail -f /dev/null")
  assert_eq(image.ready_conditions().length(), 1)
}

///|
test "environment overrides are last-wins" {
  let image = GenericImage::new("alpine", "latest")
    .with_env_var("A", "old")
    .with_env_var("B", "value")
    .with_env_var("A", "new")
  assert_eq(image.env_vars.length(), 2)
  assert_eq(image.env_vars[0].0, "B")
  assert_eq(image.env_vars[1].0, "A")
  assert_eq(image.env_vars[1].1, "new")
}

///|
test "image reference must be nonempty" {
  assert_true(try { ignore(GenericImage::new("", "latest")); false } catch { _ => true })
  assert_true(try { ignore(GenericImage::new("alpine", "")); false } catch { _ => true })
}

///|
test "container names use upstream Apple validation" {
  assert_true(valid_container_name("test-container"))
  assert_true(valid_container_name("a.b_c"))
  assert_true(!valid_container_name("a"))
  assert_true(!valid_container_name("-bad"))
  assert_true(!valid_container_name("bad/name"))
  assert_true(!valid_container_name("a" + "b".repeat(63)))
}
