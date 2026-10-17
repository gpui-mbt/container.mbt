///|
/// Issue 0046 — privileged / cap_add / cap_drop / shm_size / init.

///|
test "security options serialize into docker run argv" {
  let image = GenericImage::new("alpine", "latest")
    .with_privileged(true)
    .with_cap_add("SYS_ADMIN")
    .with_cap_add("NET_RAW")
    .with_cap_drop("MKNOD")
    .with_shm_size(67108864L)
    .with_init()
  let args = build_run_args(
    Docker,
    image,
    attempt=fixture_attempt("sec", "fixture-run-id"),
  ).join(" ")
  assert_true(args.contains("--privileged"))
  assert_true(args.contains("--cap-add SYS_ADMIN --cap-add NET_RAW"))
  assert_true(args.contains("--cap-drop MKNOD"))
  assert_true(args.contains("--shm-size 67108864"))
  assert_true(args.contains("--init"))
}

///|
test "default image emits no security flags" {
  let args = build_run_args(
    Docker,
    GenericImage::new("alpine", "latest"),
    attempt=fixture_attempt("plain", "fixture-run-id"),
  ).join(" ")
  for
    flag in ["--privileged", "--cap-add", "--cap-drop", "--shm-size", "--init"] {
    assert_true(!args.contains(flag))
  }
}

///|
test "privileged is last-wins and never derived from other options" {
  let toggled = GenericImage::new("a", "1")
    .with_privileged(true)
    .with_privileged(false)
  assert_true(!toggled.privileged)
  // cap_add must NOT imply privileged (upstream contract).
  let capped = GenericImage::new("a", "1").with_cap_add("SYS_ADMIN")
  assert_true(!capped.privileged)
}

///|
test "shm_size is last-wins and rejects negatives" {
  let img = GenericImage::new("a", "1")
    .with_shm_size(1024L)
    .with_shm_size(2048L)
  assert_eq(img.shm_size_bytes, Some(2048L))
  let r = try {
    ignore(GenericImage::new("a", "1").with_shm_size(-1L))
    false
  } catch {
    _ => true
  }
  assert_true(r)
}

///|
test "capability names are validated at set time" {
  for bad in ["", "has space", "with-dash", "new\nline", "semi;colon"] {
    let r = try {
      ignore(GenericImage::new("a", "1").with_cap_add(bad))
      false
    } catch {
      _ => true
    }
    assert_true(r)
  }
  // Valid forms: bare and CAP_-prefixed names.
  ignore(
    GenericImage::new("a", "1")
    .with_cap_add("SYS_ADMIN")
    .with_cap_drop("CAP_MKNOD")
    .with_cap_add("net_raw"),
  )
}

///|
test "security options reach the Engine HostConfig" {
  let image = GenericImage::new("alpine", "latest")
    .with_privileged(true)
    .with_cap_add("SYS_ADMIN")
    .with_cap_drop("MKNOD")
    .with_shm_size(33554432L)
    .with_init()
  let body = create_request(image).to_json()
  assert_true(body.contains("\"Privileged\":true"))
  assert_true(body.contains("\"Init\":true"))
  assert_true(body.contains("\"CapAdd\":[\"SYS_ADMIN\"]"))
  assert_true(body.contains("\"CapDrop\":[\"MKNOD\"]"))
  assert_true(body.contains("\"ShmSize\":33554432"))
  // Defaults stay explicit-false (upstream serializes them always).
  let bare = create_request(GenericImage::new("a", "1")).to_json()
  assert_true(bare.contains("\"Privileged\":false"))
  assert_true(bare.contains("\"Init\":false"))
  assert_true(!bare.contains("CapAdd"))
}

///|
test "security capability verdicts" {
  assert_true(capability(DirectDocker, Privileged) is Supported)
  assert_true(capability(CliDocker, Privileged) is Supported)
  for s in [Privileged, Capabilities, ShmSize, Init] {
    match capability(CliApple, s) {
      Rejected(_) => ()
      _ => fail("CliApple must reject security options")
    }
  }
  // Bare image does not trip the security cells.
  assert_true(
    !settings_in_use(GenericImage::new("a", "1"))
    .iter()
    .any(fn(s) {
      s is Privileged || s is Capabilities || s is ShmSize || s is Init
    }),
  )
}
