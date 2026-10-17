///|
test "normalize image references" {
  assert_eq(normalize_image_reference("alpine:3.20"), "docker.io/library/alpine:3.20")
  assert_eq(normalize_image_reference("user/repo:tag"), "docker.io/user/repo:tag")
  assert_eq(
    normalize_image_reference("ghcr.io/apple/containerization/vminit:0.31.0"),
    "ghcr.io/apple/containerization/vminit:0.31.0",
  )
  assert_eq(normalize_image_reference("localhost:5000/x:y"), "localhost:5000/x:y")
}

///|
test "effective command follows Docker override semantics" {
  let config : ImageConfig = {
    entrypoint: Some(["/bin/sh"]),
    cmd: Some(["-c", "echo hi"]),
  }
  let (exe, args) = effective_command(config, None, [])
  assert_eq(exe, "/bin/sh")
  assert_eq(args.length(), 2)
  let (exe2, args2) = effective_command(config, None, ["printf", "x"])
  assert_eq(exe2, "/bin/sh")
  assert_eq(args2.length(), 2)
  let (exe3, args3) = effective_command(config, Some(""), [])
  assert_eq(exe3, "-c")
  assert_eq(args3.length(), 1)
}

///|
async test "live image resolve and config" {
  if !is_apple() {
    println("SKIP (未実行): Apple Container XPC requires macOS")
    return
  }
  let descriptor = resolve_or_pull("alpine:3.20", None) catch {
    e => {
      println("resolve failed: \{e}")
      fail("resolve failed")
    }
  } noraise {
    d => d
  }
  let config = resolve_image_config(descriptor, None)
  guard config.cmd is Some(cmd) && cmd.length() > 0 else {
    fail("alpine image config has no CMD")
  }
  let (exe, _) = effective_command(config, None, [])
  guard exe != "" else { fail("effective command is empty") }
}
