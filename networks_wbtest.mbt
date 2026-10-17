///|
/// `NetworkSettings.Networks` fixtures for 0015.
fn networks_fixture() -> Json raise {
  @json.parse(
    "{\"bridge\":{\"IPAddress\":\"172.17.0.2\",\"Gateway\":\"172.17.0.1\"},\"zeta\":{\"IPAddress\":\"10.9.0.5\"},\"alpha\":{\"IPAddress\":\"fd00::42\"}}",
  )
}

///|
test "bridge_ip picks the alphabetically first network" {
  // Keys arrive as bridge, zeta, alpha — "alpha" must win regardless
  // of document or connection order.
  let nets = ContainerNetworks::parse(networks_fixture())
  assert_eq(nets.bridge_ip(container_id="abc"), "fd00::42")
  // Lexicographic order, not MoonBit's length-first String::compare:
  // "bridge" < "zeta" lexicographically even though zeta is shorter.
  let pair = ContainerNetworks::parse(
    @json.parse(
      "{\"zeta\":{\"IPAddress\":\"10.9.0.5\"},\"bridge\":{\"IPAddress\":\"172.17.0.2\"}}",
    ),
  )
  assert_eq(pair.bridge_ip(container_id="abc"), "172.17.0.2")
}

///|
test "bridge_ip returns IPv4 and IPv6 literals" {
  let v4 = ContainerNetworks::parse(
    @json.parse("{\"bridge\":{\"IPAddress\":\"172.17.0.2\"}}"),
  )
  assert_eq(v4.bridge_ip(container_id="abc"), "172.17.0.2")
  let v6 = ContainerNetworks::parse(
    @json.parse("{\"bridge\":{\"IPAddress\":\"fe80::42:1\"}}"),
  )
  assert_eq(v6.bridge_ip(container_id="abc"), "fe80::42:1")
  // Embedded-IPv4 and compressed forms validate through Addr::parse.
  let mapped = ContainerNetworks::parse(
    @json.parse("{\"bridge\":{\"IPAddress\":\"::ffff:10.0.0.1\"}}"),
  )
  assert_eq(mapped.bridge_ip(container_id="abc"), "::ffff:10.0.0.1")
}

///|
test "missing or empty Networks means not connected" {
  let none_parsed = ContainerNetworks::parse(@json.parse("null"))
  try none_parsed.bridge_ip(container_id="abc") catch {
    err => {
      assert_true(err.to_string().contains("not connected"))
      assert_true(err.to_string().contains("abc"))
    }
  } noraise {
    _ => fail("expected not-connected error")
  }
  let empty = ContainerNetworks::parse(@json.parse("{}"))
  try empty.bridge_ip(container_id="abc") catch {
    err => assert_true(err.to_string().contains("not connected"))
  } noraise {
    _ => fail("expected not-connected error")
  }
}

///|
test "empty and unspecified IPAddress mean unassigned, not connected" {
  // Host networking: attached but IPAddress is "".
  let host = ContainerNetworks::parse(
    @json.parse("{\"host\":{\"IPAddress\":\"\"}}"),
  )
  try host.bridge_ip(container_id="abc") catch {
    err => {
      let msg = err.to_string()
      assert_true(msg.contains("no IP address assigned"))
      assert_true(msg.contains("host"))
      assert_true(!msg.contains("not connected"))
    }
  } noraise {
    _ => fail("expected unassigned error")
  }
  // Unspecified literals are never a successful answer either.
  let zero = ContainerNetworks::parse(
    @json.parse("{\"bridge\":{\"IPAddress\":\"0.0.0.0\"}}"),
  )
  try zero.bridge_ip(container_id="abc") catch {
    err => assert_true(err.to_string().contains("no IP address assigned"))
  } noraise {
    _ => fail("expected unassigned error")
  }
  let v6unspec = ContainerNetworks::parse(
    @json.parse("{\"bridge\":{\"IPAddress\":\"0:0:0:0:0:0:0:0\"}}"),
  )
  try v6unspec.bridge_ip(container_id="abc") catch {
    err => assert_true(err.to_string().contains("no IP address assigned"))
  } noraise {
    _ => fail("expected unassigned error")
  }
}

///|
test "invalid IP literals raise without panicking" {
  for bad in ["not-an-ip", "999.1.1.1", "1.2.3", "fe80::1%eth0", "::gggg"] {
    let nets = ContainerNetworks::parse(
      @json.parse("{\"bridge\":{\"IPAddress\":\"\{bad}\"}}"),
    )
    try nets.bridge_ip(container_id="abc") catch {
      err => {
        assert_true(err.to_string().contains("not a valid IP literal"))
        assert_true(err.to_string().contains(bad))
      }
    } noraise {
      _ => fail("expected invalid-literal error for \{bad}")
    }
  }
}

///|
test "entries lacking IPAddress record as unassigned" {
  let nets = ContainerNetworks::parse(
    @json.parse("{\"bridge\":{\"Gateway\":\"172.17.0.1\"}}"),
  )
  try nets.bridge_ip(container_id="abc") catch {
    err => assert_true(err.to_string().contains("no IP address assigned"))
  } noraise {
    _ => fail("expected unassigned error")
  }
}

///|
async test "api-path get_bridge_ip_address resolves via inspect" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        1,
        fn(_head) {
          http_200(
            "{\"State\":{\"Running\":true},\"NetworkSettings\":{\"Networks\":{\"bridge\":{\"IPAddress\":\"172.17.0.3\"}}}}",
          )
        },
        [],
      )
    })
    let client = DockerClient::new(socket_path=sock)
    assert_eq(client.get_bridge_ip_address("abc"), "172.17.0.3")
  })
}

///|
async test "api-path propagates container-not-found" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        1,
        fn(_head) {
          http_resp(
            "404", "Not Found", "{\"message\":\"No such container: deadbeef\"}",
          )
        },
        [],
      )
    })
    let client = DockerClient::new(socket_path=sock)
    try client.get_bridge_ip_address("deadbeef") catch {
      EngineError::ContainerNotFound(..) => ()
      err => fail("expected ContainerNotFound, got \{err}")
    } noraise {
      _ => fail("expected ContainerNotFound")
    }
  })
}
