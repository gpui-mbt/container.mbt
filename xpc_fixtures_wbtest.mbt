///|
async fn fixture(path : String) -> Bytes {
  @fs.read_file(path).binary()
}

///|
async test "image config fixture resolves CMD" {
  let config = parse_image_config(fixture("fixtures/xpc/image_config_alpine.json"))
  let (exe, args) = effective_command(config, None, [])
  assert_eq(exe, "/bin/sh")
  assert_eq(args.length(), 0)
}

///|
async test "containerList fixture parses ports and networks" {
  let raw = fixture("fixtures/xpc/container_list_running.json")
  let items = match @json.parse(@utf8.decode(raw)) {
    Array(items) => items
    _ => fail("fixture is not an array")
  }
  let item = items[0]
  let ports = ResolvedPorts::parse_xpc(item)
  assert_eq(ports.ipv4(ContainerPort::tcp(80)), 49152)
  assert_eq(ports.ipv6(ContainerPort::tcp(81)), 49153)
  let nets = ContainerNetworks::parse_xpc(item)
  assert_eq(nets.bridge_ip(container_id="fixture"), "192.168.64.2")
  assert_eq(nets.gateway_ip(container_id="fixture"), "192.168.64.1")
}

///|
async test "xpc error fixture is classified" {
  let err = parse_error_payload(fixture("fixtures/xpc/error_not_found.json"))
  match err {
    XpcError::Remote(code~, message~) => {
      assert_eq(code, "notFound")
      assert_true(message.contains("not found"))
    }
    _ => fail("error fixture did not decode to a Remote error")
  }
}
