///|
test "macOS options keep unspecified, empty, and explicit distinct" {
  let image = GenericImage::new("alpine", "3.20")
  assert_true(image.masked_paths is None)
  let empty = image.with_masked_paths([])
  assert_true(empty.masked_paths is Some([]))
  let explicit = empty.with_masked_paths(["/etc/secret"]).with_masked_paths(["/a", "/b"])
  match explicit.masked_paths {
    Some(paths) => {
      assert_eq(paths.length(), 2)
      assert_eq(paths[0], "/a")
    }
    None => fail("masked paths were lost")
  }
  let ro = explicit.with_readonly_paths(["/ro"])
  match ro.readonly_paths {
    Some(paths) => assert_eq(paths[0], "/ro")
    None => fail("readonly paths were lost")
  }
  assert_true(ro.ssh == false)
  assert_true(ro.with_ssh().ssh == true)
}

///|
test "kernel option last-wins and produces a kernel JSON" {
  let image = GenericImage::new("alpine", "3.20")
    .with_kernel("/tmp/a")
    .with_kernel("/tmp/b")
  match image.kernel {
    Some(path) => assert_eq(path, "/tmp/b")
    None => fail("kernel path was lost")
  }
  let json = @utf8.decode_lossy(kernel_json("/tmp/b"))
  assert_true(json.contains("\"path\":\"file:///tmp/b\""))
  assert_true(json.contains("console=hvc0"))
}

///|
test "capability matrix rejects macOS options on Linux and Apple CLI" {
  assert_true(capability(DirectXpc, Ssh) is Supported)
  assert_true(capability(DirectXpc, MaskedPaths) is Supported)
  assert_true(capability(DirectDocker, Ssh) is Rejected(_))
  assert_true(capability(CliDocker, Kernel) is Rejected(_))
  assert_true(capability(CliApple, ReadonlyPaths) is Rejected(_))
}
