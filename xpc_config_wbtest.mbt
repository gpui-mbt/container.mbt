///|
test "platform normalization matches upstream" {
  assert_eq(normalize_platform(Some("linux/amd64")), ("amd64", true, Some("linux/amd64")))
  assert_eq(normalize_platform(Some("arm64")), ("arm64", false, Some("linux/arm64")))
  assert_eq(normalize_platform(Some("linux/ppc64le")), ("arm64", false, None))
  assert_eq(normalize_platform(None), ("arm64", false, None))
}

///|
test "process user parsing handles ids, raw names, and invalid gids" {
  let id = parse_process_user(Some("1000:1001"))
  assert_true(id.stringify().contains("\"uid\":1000"))
  let root = parse_process_user(Some("root"))
  assert_true(root.stringify().contains("userString"))
  try {
    ignore(parse_process_user(Some("1000:not-a-gid")))
    fail("invalid gid was accepted")
  } catch {
    _ => ()
  }
}

///|
async test "mount JSON carries access mode and tmpfs options" {
  let image = GenericImage::new("alpine", "3.20")
    .with_mount(Mount::bind_mount("/tmp", "/data"))
    .with_mount(Mount::bind_mount("/tmp", "/ro").with_read_only())
    .with_mount(
      Mount::tmpfs_mount_options(
        "/tmp/xpc",
        TmpfsOptions::new().with_size_bytes(1048576).with_mode(0o1777),
      ),
    )
  let mounts = build_mounts(image)
  let json = j_arr(mounts).stringify()
  assert_true(json.contains("virtiofs"))
  assert_true(json.contains("tmpfs"))
  assert_true(json.contains("\"rw\""))
  assert_true(json.contains("\"ro\""))
  assert_true(json.contains("size=1048576"))
  assert_true(json.contains("mode=1777"))
}

///|
test "XPC publishedPorts parse splits IPv4/IPv6 and skips zero" {
  let item = @json.parse(
    "{\"configuration\":{\"publishedPorts\":[{\"hostAddress\":\"0.0.0.0\",\"hostPort\":8080,\"containerPort\":80,\"proto\":\"tcp\"},{\"hostAddress\":\"::\",\"hostPort\":8081,\"containerPort\":81,\"proto\":\"tcp\"},{\"hostAddress\":\"0.0.0.0\",\"hostPort\":0,\"containerPort\":82,\"proto\":\"tcp\"}]}}",
  )
  let ports = ResolvedPorts::parse_xpc(item)
  assert_eq(ports.ipv4(ContainerPort::tcp(80)), 8080)
  assert_eq(ports.ipv6(ContainerPort::tcp(81)), 8081)
  try {
    ignore(ports.ipv4(ContainerPort::tcp(82)))
    fail("hostPort=0 must not be returned")
  } catch {
    _ => ()
  }
}
