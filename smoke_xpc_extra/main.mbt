///|
/// Apple Container 1.5.0+ extra acceptance: copy-in, volume mount,
/// masked/readonly paths, and a custom kernel. Run only after the host
/// update; the verification script checks the version first.
async fn main {
  let name = "container-mbt-xpc-extra-\{@async.now()}"
  let volume = "container-mbt-xpc-extra-vol"
  let home = @env.get_env_var("HOME").unwrap_or("")
  let kernel_dir = "\{home}/Library/Application Support/com.apple.container/kernels"
  let kernels = @fs.readdir(kernel_dir) catch { _ => [] } noraise { e => e }
  let mut kernel : String? = None
  for file in kernels {
    if kernel is None && file.has_prefix("vmlinux") {
      kernel = Some(file)
    }
  }
  let kernel_path = match kernel {
    Some(file) => Some("\{kernel_dir}/\{file}")
    None => None
  }
  let image = @container.GenericImage::new("alpine", "3.20")
    .with_container_name(name)
    .with_cmd(["sh", "-c", "echo extra-ready; sleep 60"])
    .with_wait_for(@container.WaitFor::message_on_stdout("extra-ready"))
    .with_startup_timeout(120000)
    .with_ssh()
    .with_masked_paths(["/etc/passwd"])
    .with_readonly_paths(["/etc/hosts"])
    .with_mount(@container.Mount::volume_mount(volume, "/vol"))
    .with_copy_to("/copied", @container.CopyDataSource::data(b"copy-data"))
  let image = match kernel_path {
    Some(path) => image.with_kernel(path)
    None => image
  }
  let container = image.start(@container.AppleContainer)
  errdefer (container.rm() catch { _ => () })

  let copied = container.exec(["cat", "/copied"])
  guard copied.exit_code() == 0 && copied.stdout() == "copy-data" else {
    fail("copy-in failed: exit=\{copied.exit_code()} out=\{copied.stdout()} err=\{copied.stderr()}")
  }
  let vol = container.exec(["sh", "-c", "echo v > /vol/x && cat /vol/x"])
  guard vol.exit_code() == 0 && vol.stdout().trim() == "v" else {
    fail("volume mount failed: \{vol.stderr()}")
  }
  let masked = container.exec(["sh", "-c", "head -c 1 /etc/passwd"])
  guard masked.exit_code() != 0 || masked.stdout() == "" else {
    fail("masked path /etc/passwd was still readable")
  }
  let ro_write = container.exec(["sh", "-c", "echo x >> /etc/hosts"])
  guard ro_write.exit_code() != 0 else {
    fail("readonly path /etc/hosts accepted a write")
  }
  container.stop()
  container.rm()
  println("Apple XPC extra E2E PASS (kernel=\{kernel_path.unwrap_or("default")})")
}
