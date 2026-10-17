///|
fn fixture_container(host_port : Int32) -> Container raise {
  {
    id: "test",
    runtime: Docker,
    mappings: [PortMapping::new(host_port, ContainerPort::tcp(80))],
    removed: false,
    resolved_ports: None,
    inspect_obj: None,
    client: None,
  }
}

///|
/// 0036: request wire format — Host, Connection: close, reserved
/// headers skipped, Content-Length only when a body exists.
test "probe request wire format" {
  let s = HttpWaitStrategy::new("/healthz")
    .with_verb("POST")
    .with_request_header("X-Custom", "yes")
    .with_request_header("Host", "evil")
    .with_request_header("Authorization", "x")
    .with_request_body(b"ab")
  let req = build_http_probe(s, "127.0.0.1", 8080)
  let text = @utf8.decode_lossy(req[:])
  assert_true(text.has_prefix("POST /healthz HTTP/1.1\r\n"))
  assert_true(text.contains("Host: 127.0.0.1:8080\r\n"))
  assert_true(text.contains("Connection: close\r\n"))
  assert_true(text.contains("X-Custom: yes\r\n"))
  assert_true(text.contains("Content-Length: 2\r\n"))
  // reserved user headers dropped — only the builder's Host survives
  assert_false(text.contains("Host: evil"))
  assert_false(text.contains("Authorization: x"))
  assert_true(text.has_suffix("\r\n\r\nab"))
  // IPv6 host is bracketed
  let req6 = build_http_probe(HttpWaitStrategy::new("/"), "::1", 9000)
  assert_true(@utf8.decode_lossy(req6[:]).contains("Host: [::1]:9000\r\n"))
}

///|
/// 0036: matching — status, header names case-insensitive, body
/// substring; mismatch reports why.
test "response matching rules" {
  let s = HttpWaitStrategy::new("/")
    .with_expected_status(200)
    .with_expected_header("Content-Type", "text/plain")
    .with_expected_body("ready")
  assert_true(
    strategy_matches(
      s,
      200,
      [("content-type", "text/plain")],
      @utf8.encode("service ready now"),
    )
    is None,
  )
  assert_true(
    strategy_matches(s, 404, [("content-type", "text/plain")], b"ready")
    is Some(_),
  )
  assert_true(strategy_matches(s, 200, [("X-Other", "v")], b"ready") is Some(_))
  assert_true(
    strategy_matches(s, 200, [("content-type", "text/plain")], b"nope")
    is Some(_),
  )
}

///|
/// 0036: a matcher-less strategy and a container with no published
/// ports both fail before any connect attempt.
async test "pre-flight rejects bad configuration" {
  let r1 = try {
    ignore(
      fixture_container(18080).http_wait_until(
        HttpWaitStrategy::new("/"),
        @async.now() + 5000,
      ),
    )
    "connected"
  } catch {
    e => if "\{e}".contains("no matcher") { "no-matcher" } else { "other:\{e}" }
  }
  assert_eq(r1, "no-matcher")
  // no published mapping → ConfigError path
  let bare : Container = {
    id: "t",
    runtime: Docker,
    mappings: [],
    removed: false,
    resolved_ports: None,
    inspect_obj: None,
    client: None,
  }
  let r2 = try {
    bare.http_wait_until(
      HttpWaitStrategy::new("/").with_expected_status(200),
      @async.now() + 5000,
    )
    "connected"
  } catch {
    e =>
      if "\{e}".contains("misconfigured") {
        "misconfigured"
      } else {
        "other:\{e}"
      }
  }
  assert_eq(r2, "misconfigured")
}

///|
/// 0036: end-to-end over a real TCP fixture — non-HTTP bytes, then a
/// real 200, proving retries reclassify instead of failing fast.
async test "http wait retries past non-HTTP noise" {
  let server = @socket.TcpServer::TcpServer(
    @socket.Addr::parse("127.0.0.1:0"),
    reuse_addr=true,
  )
  let port = server.addr.port()
  let served : Ref[Int32] = { val: 0, }
  @async.with_task_group(group => {
    group.spawn_bg(allow_failure=true, () => {
      // bounded server lifetime so the task group can exit
      ignore(
        @async.with_timeout_opt(3000, () => {
          server.run_forever((conn, _addr) => {
            served.val += 1
            if served.val == 1 {
              // first attempt: TLS-handshake-like noise, not HTTP
              conn.write(b"\x16\x03\x01\x00\x2a")
              return
            }
            conn.write(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nready")
          })
        }),
      )
    })
    let container = fixture_container(port)
    container.http_wait_until(
      HttpWaitStrategy::new("/").with_expected_status(200),
      @async.now() + 8000,
    )
  })
  assert_true(served.val >= 2)
}

///|
/// 0036: a plain mismatch (right protocol, wrong status) keeps
/// retrying until the deadline rather than succeeding early.
async test "mismatch retries until deadline" {
  let server = @socket.TcpServer::TcpServer(
    @socket.Addr::parse("127.0.0.1:0"),
    reuse_addr=true,
  )
  let port = server.addr.port()
  let served : Ref[Int32] = { val: 0, }
  @async.with_task_group(group => {
    group.spawn_bg(allow_failure=true, () => {
      ignore(
        @async.with_timeout_opt(1500, () => {
          server.run_forever((conn, _addr) => {
            served.val += 1
            conn.write(b"HTTP/1.1 503 Nope\r\nContent-Length: 0\r\n\r\n")
          })
        }),
      )
    })
    let container = fixture_container(port)
    let r = try {
      container.http_wait_until(
        HttpWaitStrategy::new("/")
        .with_expected_status(200)
        .with_poll_interval(30),
        @async.now() + 300,
      )
      "ready"
    } catch {
      e => if "\{e}".contains("deadline") { "deadline" } else { "other:\{e}" }
    }
    assert_eq(r, "deadline")
  })
  assert_true(served.val > 3)
}

///|
/// 0036: connection refused retries — nothing listens, deadline wins.
async test "connection refused retries to deadline" {
  // find a free port by binding then closing
  let probe = @socket.TcpServer::TcpServer(
    @socket.Addr::parse("127.0.0.1:0"),
    reuse_addr=true,
  )
  let port = probe.addr.port()
  probe.close()
  let container = fixture_container(port)
  let r = try {
    container.http_wait_until(
      HttpWaitStrategy::new("/")
      .with_expected_status(200)
      .with_poll_interval(20),
      @async.now() + 300,
    )
    "ready"
  } catch {
    e => if "\{e}".contains("deadline") { "deadline" } else { "other:\{e}" }
  }
  assert_eq(r, "deadline")
}

///|
/// 0036: a slow response exceeds the per-request timeout and the wait
/// proceeds to the next poll (or deadline) instead of hanging.
async test "request timeout bounds one attempt" {
  let server = @socket.TcpServer::TcpServer(
    @socket.Addr::parse("127.0.0.1:0"),
    reuse_addr=true,
  )
  let port = server.addr.port()
  let answered : Ref[Int32] = { val: 0, }
  @async.with_task_group(group => {
    group.spawn_bg(allow_failure=true, () => {
      ignore(
        @async.with_timeout_opt(3000, () => {
          server.run_forever((conn, _addr) => {
            // answer slowly on attempt 2+, never on attempt 1
            if answered.val > 0 {
              conn.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
            } else {
              answered.val += 1
              @async.sleep(2000)
              conn.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
            }
          })
        }),
      )
    })
    let container = fixture_container(port)
    container.http_wait_until(
      HttpWaitStrategy::new("/")
      .with_expected_status(200)
      .with_request_timeout(200)
      .with_poll_interval(20),
      @async.now() + 8000,
    )
  })
}

///|
/// 0036: WaitFor::http is in the capability matrix — direct adapter
/// supports it, CLI adapters refuse before side effects.
test "http wait capability gate" {
  assert_true(capability(DirectDocker, HttpWait) is Supported)
  assert_true(capability(CliDocker, HttpWait) is NotYetImplemented(_))
  assert_true(capability(CliApple, HttpWait) is NotYetImplemented(_))
}
