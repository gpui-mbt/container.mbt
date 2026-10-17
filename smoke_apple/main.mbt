///|
/// Docker exits non-zero for a missing container; Apple exits 0 with
/// `[]`. Treat both as "not present".
fn inspect_has_object(output : @shell.Output) -> Bool {
  if output.exit_code() != 0 {
    return false
  }
  let text = output.stdout().trim()
  if text == "" || text == "[]" {
    return false
  }
  true
}

///|
/// True when something is already listening on `127.0.0.1:<port>` or on
/// the wildcard address. `lsof` is authoritative (it sees wildcard
/// listeners that a 127.0.0.1 bind can miss); the TCP connect probe is
/// the fallback when lsof cannot be spawned.
async fn port_is_listening(port : Int) -> Bool {
  let probe_addr = @socket.Addr::parse("127.0.0.1:\{port}")
  let lsof : @shell.Output? = Some(
    @shell.Cmd(
      "lsof",
      ["-nP", "-iTCP:\{port}", "-sTCP:LISTEN"],
    ).output(timeout_ms=5000, max_output_bytes=65536),
  ) catch {
    _ => None
  }
  match lsof {
    Some(out) if out.exit_code() == 1 => false
    Some(out) if out.exit_code() == 0 => out.stdout().trim() != ""
    _ => {
      let occupied : Bool = try {
        let conn = @socket.Tcp::connect(probe_addr)
        conn.close()
        true
      } catch {
        _ => false
      } noraise {
        v => v
      }
      occupied
    }
  }
}

///|
/// Parse the optional test port override without pulling in an external
/// conversion package.
fn parse_port(value : String) -> Int raise {
  guard value != "" else { fail("published port is empty") }
  let mut n = 0
  for c in value {
    guard c is ('0'..<='9') else { fail("published port is not an integer: \{value}") }
    n = n * 10 + (c.to_int() - '0'.to_int())
    guard n <= 65535 else { fail("published port is out of range: \{value}") }
  }
  guard n > 0 else { fail("published port must be positive: \{value}") }
  n
}

///|
/// Apple Container CLI E2E. Run only on a physical macOS 26 Apple Silicon host.
///
/// Covers issue 0002 (lifecycle + run-failure cleanup) and 0003 (host
/// TCP reachability for a fixed published port). The port defaults to
/// 18080; `CONTAINER_MBT_APPLE_PORT` exists so the acceptance can be
/// re-run on a host where 18080 is occupied by an unrelated service.
async fn main {
  let port = match @env.get_env_var("CONTAINER_MBT_APPLE_PORT") {
    Some(v) if v != "" => parse_port(v)
    _ => 18080
  }
  // 0003: a port already held by another process is an environment
  // error, not a silent skip.
  let probe_addr = @socket.Addr::parse("127.0.0.1:\{port}")
  guard !(port_is_listening(port)) else {
    fail(
      "host TCP port \{port} is already in use; stop the listener before running the Apple E2E",
    )
  }

  let run_id = @async.now()
  let name = "container-mbt-apple-\{run_id}"
  let foreign = "container-mbt-apple-foreign-\{run_id}"
  let failing = "container-mbt-apple-failing-\{run_id}"
  let tcp_body = "moonbit-apple-tcp"
  // BusyBox in alpine:3.20 has no httpd applet; nc serves one request at
  // a time. The loop restarts the listener after each connection.
  let server_cmd = "echo moonbit-apple-ready; while true; do printf 'HTTP/1.1 200 OK\\r\\nContent-Length: 18\\r\\nConnection: close\\r\\n\\r\\nmoonbit-apple-tcp\\n' | nc -l -p 80; done"
  let image = @container.GenericImage::new("alpine", "3.20")
    .with_container_name(name)
    .with_cmd(["sh", "-c", server_cmd])
    .with_mapped_port(port, @container.ContainerPort::tcp(80))
    .with_wait_for(@container.WaitFor::message_on_stdout("moonbit-apple-ready"))
    .with_startup_timeout(60000)

  // 0002: an unrelated container must survive both the successful run
  // and the run-failure cleanup path. It is created with an exact name
  // and removed only by that name at the end.
  let foreign_run = @shell.Cmd(
    "container",
    ["run", "--detach", "--name", foreign, "alpine:3.20", "sh", "-c", "sleep 60"],
  ).output(timeout_ms=60000, max_output_bytes=1048576)
  guard foreign_run.exit_code() == 0 else {
    fail("could not create the foreign-container fixture: \{foreign_run.stderr()}")
  }
  defer {
    let _ = @shell.Cmd("container", ["delete", "--force", foreign]).output(
      timeout_ms=30000,
      max_output_bytes=1048576,
    )
  }

  let container = image.start_cli(@container.AppleContainer)
  // Why not retain a newly created VM after a failed assertion.
  errdefer (container.rm() catch { _ => () })

  // 0003: the fixed port number is reported and is actually reachable.
  guard container.get_host_port_ipv4(@container.ContainerPort::tcp(80)) == port else {
    fail("Apple Container reported an unexpected fixed host port")
  }
  let tcp = @socket.Tcp::connect(probe_addr)
  defer tcp.close()
  tcp.write(
    b"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
  )
  let response_bytes = tcp.read_all()
  let response = @utf8.decode_lossy(response_bytes.binary())
  guard response.contains("200 OK") && response.contains(tcp_body) else {
    fail(
      "host TCP request to 127.0.0.1:\{port} did not return the fixture body: \{response}",
    )
  }

  let exec = container.exec(["sh", "-c", "printf moonbit-apple-e2e"])
  guard exec.exit_code() == 0 && exec.stdout() == "moonbit-apple-e2e" else {
    fail("Apple Container exec failed: \{exec.stderr()}")
  }
  let logs = container.logs()
  guard logs.exit_code() == 0 && logs.stdout().contains("moonbit-apple-ready") else {
    fail("Apple Container logs did not contain the startup marker")
  }
  container.stop()
  container.rm()
  let removed = @shell.Cmd("container", ["inspect", name]).output(
    timeout_ms=15000,
    max_output_bytes=1048576,
  )
  guard removed.exit_code() != 0 || !inspect_has_object(removed) else {
    fail("Apple Container still exists after removal")
  }

  // 0002: a CLI run that fails before its ID can be read must not leave
  // an orphan, and must not touch the foreign container above.
  let failing_image = @container.GenericImage::new("alpine", "3.20")
    .with_container_name(failing)
    .with_entrypoint("/nonexistent-container-mbt-entrypoint")
    .with_cmd(["true"])
    .with_startup_timeout(5000)
  let failed = try {
    let c = failing_image.start_cli(@container.AppleContainer)
    c.rm() catch { _ => () }
    false
  } catch {
    _ => true
  }
  guard failed else {
    fail("the invalid-entrypoint run unexpectedly succeeded")
  }
  let failed_probe = @shell.Cmd("container", ["inspect", failing]).output(
    timeout_ms=15000,
    max_output_bytes=1048576,
  )
  guard !inspect_has_object(failed_probe) else {
    fail("the failed CLI run left an owned container behind: \{failing}")
  }
  let foreign_probe = @shell.Cmd("container", ["inspect", foreign]).output(
    timeout_ms=15000,
    max_output_bytes=1048576,
  )
  guard inspect_has_object(foreign_probe) else {
    fail("the failed CLI run removed an unrelated container: \{foreign}")
  }

  println("Apple Container lifecycle E2E PASS")
}
