///|
test "TCP, UDP and SCTP port formats match upstream" {
  assert_eq(ContainerPort::tcp(80).as_string(), "80/tcp")
  assert_eq(ContainerPort::udp(53).as_string(), "53/udp")
  assert_eq(ContainerPort::sctp(123).as_string(), "123/sctp")
  assert_eq(
    PortMapping::new(8080, ContainerPort::tcp(80)).as_publish_argument(),
    "8080:80/tcp",
  )
  assert_eq(
    PortMapping::new(0, ContainerPort::tcp(80)).as_publish_argument(),
    "80/tcp",
  )
}

///|
test "out-of-range ports are rejected" {
  for invalid in [-1, 0, 65536] {
    assert_true(
      try {
        ignore(ContainerPort::tcp(invalid))
        false
      } catch {
        _ => true
      },
    )
  }
  for invalid in [-1, 65536] {
    assert_true(
      try {
        ignore(PortMapping::new(invalid, ContainerPort::tcp(80)))
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "container ports identify both number and protocol" {
  assert_true(same_port(ContainerPort::tcp(80), ContainerPort::tcp(80)))
  assert_true(!same_port(ContainerPort::tcp(80), ContainerPort::udp(80)))
  assert_true(!same_port(ContainerPort::tcp(80), ContainerPort::tcp(81)))
}

///|
/// A realistic `NetworkSettings.Ports` object: dual-stack binding on
/// 80/tcp, a udp sibling on the same number, a null binding (exposed
/// but unassigned), and malformed entries that must be skipped.
fn ports_fixture() -> Json raise {
  @json.parse(
    "{\"80/tcp\":[{\"HostIp\":\"0.0.0.0\",\"HostPort\":\"32768\"},{\"HostIp\":\"::\",\"HostPort\":\"32769\"}],\"80/udp\":[{\"HostIp\":\"0.0.0.0\",\"HostPort\":\"32770\"}],\"443/tcp\":null,\"53/udp\":[],\"bad/key\":[{\"HostIp\":\"0.0.0.0\",\"HostPort\":\"1\"}],\"90/sctp\":[{\"HostIp\":\"\",\"HostPort\":\"32900\"}],\"91/tcp\":[{\"HostIp\":\"0.0.0.0\",\"HostPort\":\"0\"},{\"HostIp\":\"0.0.0.0\",\"HostPort\":\"33000\"}]}",
  )
}

///|
test "resolved ports split IPv4/IPv6 and keep protocols separate" {
  let ports = ResolvedPorts::parse(ports_fixture())
  assert_eq(ports.ipv4(ContainerPort::tcp(80)), 32768)
  assert_eq(ports.ipv6(ContainerPort::tcp(80)), 32769)
  assert_eq(ports.ipv4(ContainerPort::udp(80)), 32770)
  // Empty HostIp still counts as an IPv4-family binding.
  assert_eq(ports.ipv4(ContainerPort::sctp(90)), 32900)
}

///|
test "unexposed and unassigned ports raise distinct errors" {
  let ports = ResolvedPorts::parse(ports_fixture())
  // 443/tcp has a null binding: exposed but unassigned.
  try ports.ipv4(ContainerPort::tcp(443)) catch {
    err => {
      let msg = err.to_string()
      assert_true(msg.contains("exposed"))
      assert_true(msg.contains("no IPv4 host port"))
    }
  } noraise {
    _ => fail("expected unassigned error")
  }
  // 53/udp has an empty binding list: same unassigned class.
  try ports.ipv4(ContainerPort::udp(53)) catch {
    err => assert_true(err.to_string().contains("no IPv4 host port"))
  } noraise {
    _ => fail("expected unassigned error")
  }
  // Never exposed at all.
  try ports.ipv4(ContainerPort::tcp(8080)) catch {
    err => assert_true(err.to_string().contains("not exposed"))
  } noraise {
    _ => fail("expected not-exposed error")
  }
  // IPv6-only bindings must not satisfy an IPv4 lookup.
  try ports.ipv4(ContainerPort::tcp(80)) |> ignore catch {
    _ => fail("80/tcp has an IPv4 binding")
  } noraise {
    _ => ()
  }
}

///|
test "malformed keys and non-numeric or zero host ports are skipped" {
  let ports = ResolvedPorts::parse(ports_fixture())
  // "bad/key" was skipped entirely → not exposed (not a crash).
  try ports.ipv4(ContainerPort::tcp(1)) catch {
    err => assert_true(err.to_string().contains("not exposed"))
  } noraise {
    _ => fail("expected not-exposed error")
  }
  // "91/tcp" had a HostPort 0 binding (skipped) and a valid one.
  assert_eq(ports.ipv4(ContainerPort::tcp(91)), 33000)
  // Never resolves to 0.
  assert_true(
    try {
      ignore(ports.ipv4(ContainerPort::tcp(91)))
      true
    } catch {
      _ => false
    },
  )
}

///|
test "missing NetworkSettings or Ports resolves to empty" {
  let ports = ResolvedPorts::parse(@json.parse("null"))
  try ports.ipv4(ContainerPort::tcp(80)) catch {
    err => assert_true(err.to_string().contains("not exposed"))
  } noraise {
    _ => fail("expected not-exposed error")
  }
}

///|
async test "api-path get_host_port resolves via inspect" {
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
        2,
        fn(_head) {
          http_200(
            "{\"State\":{\"Running\":true},\"NetworkSettings\":{\"Ports\":{\"80/tcp\":[{\"HostIp\":\"0.0.0.0\",\"HostPort\":\"49153\"},{\"HostIp\":\"::\",\"HostPort\":\"49154\"}]}}}",
          )
        },
        [],
      )
    })
    let client = DockerClient::new(socket_path=sock)
    assert_eq(client.get_host_port_ipv4("abc", ContainerPort::tcp(80)), 49153)
    assert_eq(client.get_host_port_ipv6("abc", ContainerPort::tcp(80)), 49154)
  })
}

///|
async test "api-path reports unassigned and unexposed distinctly" {
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
        2,
        fn(_head) {
          http_200(
            "{\"State\":{\"Running\":false},\"NetworkSettings\":{\"Ports\":{\"80/tcp\":null}}}",
          )
        },
        [],
      )
    })
    let client = DockerClient::new(socket_path=sock)
    // Exposed but unassigned.
    try client.get_host_port_ipv4("abc", ContainerPort::tcp(80)) catch {
      err => assert_true(err.to_string().contains("no IPv4 host port"))
    } noraise {
      _ => fail("expected unassigned error")
    }
    // Not exposed at all.
    try client.get_host_port_ipv4("abc", ContainerPort::tcp(81)) catch {
      err => assert_true(err.to_string().contains("not exposed"))
    } noraise {
      _ => fail("expected not-exposed error")
    }
  })
}
