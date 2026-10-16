///|
test "TCP, UDP and SCTP port formats match upstream" {
  assert_eq(ContainerPort::tcp(80).as_string(), "80/tcp")
  assert_eq(ContainerPort::udp(53).as_string(), "53/udp")
  assert_eq(ContainerPort::sctp(123).as_string(), "123/sctp")
  assert_eq(PortMapping::new(8080, ContainerPort::tcp(80)).as_publish_argument(), "8080:80/tcp")
  assert_eq(PortMapping::new(0, ContainerPort::tcp(80)).as_publish_argument(), "80/tcp")
}

///|
test "out-of-range ports are rejected" {
  for invalid in [-1, 0, 65536] {
    assert_true(try { ignore(ContainerPort::tcp(invalid)); false } catch { _ => true })
  }
  for invalid in [-1, 65536] {
    assert_true(
      try { ignore(PortMapping::new(invalid, ContainerPort::tcp(80))); false } catch { _ => true },
    )
  }
}

///|
test "container ports identify both number and protocol" {
  assert_true(same_port(ContainerPort::tcp(80), ContainerPort::tcp(80)))
  assert_true(!same_port(ContainerPort::tcp(80), ContainerPort::udp(80)))
  assert_true(!same_port(ContainerPort::tcp(80), ContainerPort::tcp(81)))
}
