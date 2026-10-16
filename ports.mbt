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
  number : Int
  protocol : Protocol
}

///|
pub fn ContainerPort::new(number : Int, protocol : Protocol) -> ContainerPort raise {
  guard number >= 1 && number <= 65535 else {
    fail("container port must be in 1..65535")
  }
  { number, protocol, }
}

///|
pub fn ContainerPort::tcp(number : Int) -> ContainerPort raise {
  ContainerPort::new(number, Tcp)
}

///|
pub fn ContainerPort::udp(number : Int) -> ContainerPort raise {
  ContainerPort::new(number, Udp)
}

///|
pub fn ContainerPort::sctp(number : Int) -> ContainerPort raise {
  ContainerPort::new(number, Sctp)
}

///|
pub fn ContainerPort::number(self : ContainerPort) -> Int {
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
  host_port : Int
  container_port : ContainerPort
}

///|
pub fn PortMapping::new(host_port : Int, container_port : ContainerPort) -> PortMapping raise {
  guard host_port >= 0 && host_port <= 65535 else {
    fail("host port must be in 0..65535")
  }
  { host_port, container_port, }
}

///|
pub fn PortMapping::host_port(self : PortMapping) -> Int {
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
