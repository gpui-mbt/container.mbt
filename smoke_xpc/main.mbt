///|
/// Apple Container XPC native E2E (issue 0032). No `container` CLI is
/// spawned by this program; the run is executed with a PATH that cannot
/// resolve it.
async fn main {
  let run_id = @async.now()
  let name = "container-mbt-xpc-\{run_id}"
  let body = "moonbit-xpc-tcp"
  let server_cmd = "echo xpc-ready; (while true; do echo xpc-tick; sleep 0.2; done) & while true; do printf 'HTTP/1.1 200 OK\\r\\nContent-Length: 15\\r\\nConnection: close\\r\\n\\r\\nmoonbit-xpc-tcp\\n' | nc -l -p 80; done"
  let host_dir = @fs.tmpdir(prefix="container-mbt-xpc-mount")
  let host_file = "\{host_dir}/hello"
  @fs.write_file(host_file, b"bind-hello")
  let image = @container.GenericImage::new("alpine", "3.20")
    .with_container_name(name)
    .with_cmd(["sh", "-c", server_cmd])
    .with_mapped_port(0, @container.ContainerPort::tcp(80))
    .with_mount(@container.Mount::bind_mount(host_dir, "/data"))
    .with_mount(
      @container.Mount::bind_mount(host_dir, "/ro").with_read_only(),
    )
    .with_mount(@container.Mount::tmpfs_mount("/tmp/xpc-tmpfs"))
    .with_wait_for(@container.WaitFor::message_on_stdout("xpc-ready"))
    .with_startup_timeout(120000)
  let before_fds = @container.count_open_fds()
  println("[xpc] starting")
  let container = image.start(@container.AppleContainer)
  println("[xpc] started \{container.id()}")
  errdefer (container.rm() catch { _ => () })

  // Dynamic published port: hostPort=0 is pre-allocated by the XPC path.
  let host_port = container.get_host_port_ipv4(@container.ContainerPort::tcp(80))
  guard host_port > 0 else { fail("dynamic host port was not resolved") }
  let addr = @socket.Addr::parse("127.0.0.1:\{host_port}")
  let bridge = container.get_bridge_ip_address()
  let gateway = container.get_host_gateway_address()
  guard bridge.contains(".") && gateway.contains(".") else {
    fail("bridge/gateway resolution failed: bridge=\{bridge} gateway=\{gateway}")
  }
  let tcp = @socket.Tcp::connect(addr)
  tcp.write(b"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
  let response = @utf8.decode_lossy(tcp.read_all().binary())
  tcp.close()
  guard response.contains("200 OK") && response.contains(body) else {
    fail("host TCP request did not return the fixture body: \{response}")
  }

  println("[xpc] exec")
  let exec = container.exec(["sh", "-c", "printf out; printf err 1>&2; exit 3"])
  guard exec.exit_code() == 3 && exec.stdout() == "out" && exec.stderr() == "err" else {
    fail(
      "exec mismatch: exit=\{exec.exit_code()} out=\{exec.stdout()} err=\{exec.stderr()}",
    )
  }
  println("[xpc] bind read")
  let bind_read = container.exec(["cat", "/data/hello"])
  guard bind_read.exit_code() == 0 && bind_read.stdout() == "bind-hello" else {
    fail("bind mount read failed: \{bind_read.stderr()}")
  }
  println("[xpc] ro write")
  let ro_write = container.exec(["sh", "-c", "echo nope > /ro/nope"])
  guard ro_write.exit_code() != 0 else {
    fail("read-only bind mount accepted a write")
  }
  println("[xpc] tmpfs")
  let tmpfs = container.exec(["sh", "-c", "echo tmp > /tmp/xpc-tmpfs/x && cat /tmp/xpc-tmpfs/x"])
  guard tmpfs.exit_code() == 0 && tmpfs.stdout().contains("tmp") else {
    fail("tmpfs write/read failed: \{tmpfs.stderr()}")
  }
  println("[xpc] logs")
  let big = container.exec(["sh", "-c", "yes x | head -c 1000000"])
  guard big.exit_code() == 0 && big.stdout().length() == 1000000 else {
    fail("large exec output was not captured: \{big.stdout().length()}")
  }
  let logs = container.logs()
  guard logs.stdout().contains("xpc-ready") else {
    fail("logs did not contain the startup marker: \{logs.stdout()}")
  }
  let frames : Array[@container.LogFrame] = []
  @async.with_task_group(group => {
    let sub = container.subscribe_logs(fn(frame) { frames.push(frame) })
    group.spawn_bg(() => sub.run())
    @async.sleep(500)
    sub.stop()
  })
  guard frames.any(fn(f) { @utf8.decode_lossy(f.data()).contains("xpc-tick") }) else {
    fail("XPC log subscription did not deliver live ticks")
  }
  println("[xpc] stop")
  container.stop()
  // Repeated stop is idempotent.
  container.stop()
  println("[xpc] rm")
  container.rm()
  container.rm()
  @async.sleep(100)
  let after_fds = @container.count_open_fds()
  guard after_fds <= before_fds + 1 else {
    fail("FD count grew: before=\{before_fds} after=\{after_fds}")
  }
  println("Apple XPC lifecycle E2E PASS (host_port=\{host_port} fds=\{before_fds}->\{after_fds})")
}
