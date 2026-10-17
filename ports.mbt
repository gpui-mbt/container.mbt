///|
/// Protocols supported by the original ContainerPort API.
pub enum Protocol {
  Tcp
  Udp
  Sctp
}

///|
/// A container port, including its transport protocol.
pub struct ContainerPort {
  number : Int32
  protocol : Protocol
}

///|
pub fn ContainerPort::new(
  number : Int32,
  protocol : Protocol,
) -> ContainerPort raise {
  guard number >= 1 && number <= 65535 else {
    fail("container port must be in 1..65535")
  }
  { number, protocol, }
}

///|
pub fn ContainerPort::tcp(number : Int32) -> ContainerPort raise {
  ContainerPort::new(number, Tcp)
}

///|
pub fn ContainerPort::udp(number : Int32) -> ContainerPort raise {
  ContainerPort::new(number, Udp)
}

///|
pub fn ContainerPort::sctp(number : Int32) -> ContainerPort raise {
  ContainerPort::new(number, Sctp)
}

///|
pub fn ContainerPort::number(self : ContainerPort) -> Int32 {
  self.number
}

///|
pub fn ContainerPort::protocol_name(self : ContainerPort) -> String {
  match self.protocol {
    Tcp => "tcp"
    Udp => "udp"
    Sctp => "sctp"
  }
}

///|
pub fn ContainerPort::as_string(self : ContainerPort) -> String {
  "\{self.number}/\{self.protocol_name()}"
}

///|
/// A host-to-container port publication. Host port zero requests an ephemeral port.
pub struct PortMapping {
  host_port : Int32
  container_port : ContainerPort
}

///|
pub fn PortMapping::new(
  host_port : Int32,
  container_port : ContainerPort,
) -> PortMapping raise {
  guard host_port >= 0 && host_port <= 65535 else {
    fail("host port must be in 0..65535")
  }
  { host_port, container_port, }
}

///|
pub fn PortMapping::host_port(self : PortMapping) -> Int32 {
  self.host_port
}

///|
pub fn PortMapping::container_port(self : PortMapping) -> ContainerPort {
  self.container_port
}

///|
pub fn PortMapping::as_publish_argument(self : PortMapping) -> String {
  let port = self.container_port
  let protocol = port.protocol_name()
  if self.host_port == 0 {
    "\{port.number()}/\{protocol}"
  } else {
    "\{self.host_port}:\{port.number()}/\{protocol}"
  }
}

///|
fn same_port(a : ContainerPort, b : ContainerPort) -> Bool {
  a.number() == b.number() && a.protocol_name() == b.protocol_name()
}

///|
/// Dynamic host-port bindings resolved from `NetworkSettings.Ports`
/// (issue 0014). `exposed` records every `<num>/<proto>` key the daemon
/// reported — even ones with a null/empty binding list — so lookups can
/// distinguish "not exposed" from "exposed but unassigned". IPv4/IPv6
/// bindings are split on `HostIp`: values containing `:` go to `ipv6`,
/// everything else (incl. `0.0.0.0`/empty) to `ipv4`. This deliberate
/// split differs from upstream (which always filed under IPv4) and is
/// pinned by fixtures.
pub struct ResolvedPorts {
  priv exposed : Map[String, Bool]
  priv ipv4 : Map[String, Int32]
  priv ipv6 : Map[String, Int32]
}

///|
/// Empty resolution — every lookup reports "not exposed".
pub fn ResolvedPorts::empty() -> ResolvedPorts {
  { exposed: {}, ipv4: {}, ipv6: {}, }
}

///|
/// Parse the `Ports` object of `NetworkSettings`: `{ "<num>/<proto>":
/// [ {"HostIp": .., "HostPort": ..}, .. ] }`. Tolerant on purpose —
/// non tcp/udp/sctp protocols, non-numeric keys/ports, port 0, and
/// malformed bindings are skipped, never fatal (upstream `parse_ports`
/// tolerance). Missing `NetworkSettings`/`Ports` yields empty maps.
pub fn ResolvedPorts::parse(ports : Json) -> ResolvedPorts {
  let out : ResolvedPorts = { exposed: {}, ipv4: {}, ipv6: {}, }
  guard ports is Object(entries) else { return out }
  for key, value in entries {
    guard parse_port_key(key) is Some(valid_key) else { continue }
    out.exposed[valid_key] = true
    guard value is Array(bindings) else { continue }
    for binding in bindings {
      guard binding is Object(b) else { continue }
      let host_port = match b.get("HostPort") {
        Some(String(s)) => {
          let mut n = 0
          let mut ok = !s.is_empty()
          for c in s {
            if c is ('0'..<='9') {
              n = n * 10 + (c.to_int() - '0'.to_int())
            } else {
              ok = false
            }
          }
          if ok && n > 0 && n <= 65535 {
            Some(n)
          } else {
            None
          }
        }
        _ => None
      }
      guard host_port is Some(port_num) else { continue }
      let host_ip = match b.get("HostIp") {
        Some(String(s)) => s
        _ => ""
      }
      if host_ip.contains(":") {
        out.ipv6[valid_key] = port_num
      } else {
        out.ipv4[valid_key] = port_num
      }
    }
  }
  out
}

///|
/// `<num>/<proto>` → normalized key, or None for keys upstream would
/// also skip (unknown protocol, non-numeric/out-of-range number).
fn parse_port_key(key : String) -> String? {
  let slash = match key.find("/") {
    Some(i) => i
    None => return None
  }
  let num = key[:slash].to_owned()
  let proto = key[slash + 1:].to_owned()
  guard proto == "tcp" || proto == "udp" || proto == "sctp" else { return None }
  let mut n = 0
  guard !num.is_empty() else { return None }
  for c in num {
    guard c is ('0'..<='9') else { return None }
    n = n * 10 + (c.to_int() - '0'.to_int())
  }
  guard n >= 1 && n <= 65535 else { return None }
  Some("\{n}/\{proto}")
}

///|
/// IPv4 host port for `port`. 0 is never returned: unexposed keys and
/// exposed-but-unassigned keys raise distinct errors.
pub fn ResolvedPorts::ipv4(
  self : ResolvedPorts,
  port : ContainerPort,
) -> Int32 raise {
  let key = port.as_string()
  if self.ipv4.get(key) is Some(n) {
    return n
  }
  if self.exposed.get(key) is Some(_) {
    fail("container port \{key} is exposed but has no IPv4 host port assigned")
  }
  fail("container port \{key} is not exposed")
}

///|
/// IPv6 host port for `port`; same not-exposed vs unassigned split.
/// Snapshot `PortMapping`s are IPv4-only so they are never consulted.
pub fn ResolvedPorts::ipv6(
  self : ResolvedPorts,
  port : ContainerPort,
) -> Int32 raise {
  let key = port.as_string()
  if self.ipv6.get(key) is Some(n) {
    return n
  }
  if self.exposed.get(key) is Some(_) {
    fail("container port \{key} is exposed but has no IPv6 host port assigned")
  }
  fail("container port \{key} is not exposed")
}
