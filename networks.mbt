///|
/// Networks attached to a container, normalized from inspect's
/// `NetworkSettings.Networks`: network name → raw `IPAddress` value
/// (an empty string means attached but unassigned, e.g. host or
/// none networking).
pub struct ContainerNetworks {
  priv addrs : Map[String, String]
  priv gateways : Map[String, String]
}

///|
pub fn ContainerNetworks::empty() -> ContainerNetworks {
  { addrs: {}, gateways: {}, }
}

///|
/// Parse a `NetworkSettings.Networks` object tolerantly: entries whose
/// `IPAddress` is missing or not a string record as unassigned ("").
pub fn ContainerNetworks::parse(json : Json) -> ContainerNetworks {
  let addrs : Map[String, String] = Map([])
  let gateways : Map[String, String] = Map([])
  match json {
    Object(m) =>
      for (name, entry) in m {
        match entry {
          Object(e) => {
            match e.get("IPAddress") {
              Some(String(ip)) => addrs[name] = ip
              _ => addrs[name] = ""
            }
            match e.get("Gateway") {
              Some(String(gw)) => gateways[name] = gw
              _ => gateways[name] = ""
            }
          }
          _ => addrs[name] = ""
        }
      }
    _ => ()
  }
  { addrs, gateways, }
}

///|
/// Normalize an Apple Container network entry (`networks` array) whose
/// address fields are CIDR strings (`192.168.64.2/24`).
pub fn ContainerNetworks::parse_xpc(item : Json) -> ContainerNetworks {
  let addrs : Map[String, String] = Map([])
  let gateways : Map[String, String] = Map([])
  match item {
    Object(map) =>
      match map.get("networks") {
        Some(Array(items)) =>
          for entry in items {
            match entry {
              Object(e) => {
                let name = match e.get("network") {
                  Some(String(s)) => s
                  _ => "default"
                }
                let addr = match e.get("ipv4Address") {
                  Some(String(s)) => strip_cidr(s)
                  _ => ""
                }
                let gateway = match e.get("ipv4Gateway") {
                  Some(String(s)) => strip_cidr(s)
                  _ => ""
                }
                addrs[name] = addr
                gateways[name] = gateway
              }
              _ => ()
            }
          }
        _ => ()
      }
    _ => ()
  }
  { addrs, gateways, }
}

///|
fn strip_cidr(value : String) -> String {
  match value.find("/") {
    Some(index) => value[:index].to_owned()
    None => value
  }
}

///|
/// Validate a bare IPv4/IPv6 literal via `@socket.Addr::parse` (which
/// wants `ip:port` form, so a synthetic port is appended). Zone-indexed
/// literals are rejected — Docker bridge IPs never carry one and the
/// scope would be host-local anyway.
fn is_ip_literal(s : String) -> Bool {
  if s.is_empty() || s.contains("%") {
    return false
  }
  let candidate = if s.contains(":") { "[\{s}]:0" } else { "\{s}:0" }
  try {
    ignore(@socket.Addr::parse(candidate))
    true
  } catch {
    _ => false
  }
}

///|
/// True when `s` parses as an IP literal but names the unspecified
/// address ("0.0.0.0" / "::" in any spelling) — meaningless to dial.
fn is_unspecified_literal(s : String) -> Bool {
  if !is_ip_literal(s) {
    return false
  }
  if s.contains(":") {
    // Any spelling of :: normalizes to the same form.
    let candidate = "[\{s}]:0"
    @socket.Addr::parse(candidate).to_string().has_prefix("[::]") catch {
      _ => false
    }
  } else {
    s == "0.0.0.0"
  }
}

///|
/// The container's bridge IP: the `IPAddress` of the first network in
/// lexicographic key order (the upstream `bridge_ip_address` rule —
/// deterministic, no hardcoded network name). `lexical_compare`, not
/// `String::compare`, is what Rust's `Ord` matches: MoonBit's default
/// `Compare` for `String` orders by length first, which would pick
/// differently for e.g. "zeta" vs "bridge". Distinct errors separate
/// "not connected to any network" from "connected but no IP assigned"
/// and from an unparsable literal.
pub fn ContainerNetworks::bridge_ip(
  self : ContainerNetworks,
  container_id~ : String,
) -> String raise {
  guard self.addrs.length() > 0 else {
    fail("container \{container_id} is not connected to any network")
  }
  let names = self.addrs.keys().to_array()
  names.sort_by(fn(a, b) { String::lexical_compare(a, b) })
  let name = names[0]
  let ip = self.addrs[name]
  guard ip != "" && !is_unspecified_literal(ip) else {
    fail("container \{container_id} network \{name} has no IP address assigned")
  }
  guard is_ip_literal(ip) else {
    fail(
      "container \{container_id} network \{name}: \{ip} is not a valid IP literal",
    )
  }
  ip
}

///|
/// The container's gateway on the same first-network rule as
/// `bridge_ip`. Used by the XPC path to resolve Docker's
/// `host-gateway` equivalent.
pub fn ContainerNetworks::gateway_ip(
  self : ContainerNetworks,
  container_id~ : String,
) -> String raise {
  guard self.gateways.length() > 0 else {
    fail("container \{container_id} is not connected to any network")
  }
  let names = self.gateways.keys().to_array()
  names.sort_by(fn(a, b) { String::lexical_compare(a, b) })
  let name = names[0]
  let ip = self.gateways[name]
  guard ip != "" && !is_unspecified_literal(ip) else {
    fail("container \{container_id} network \{name} has no gateway assigned")
  }
  guard is_ip_literal(ip) else {
    fail(
      "container \{container_id} network \{name}: \{ip} is not a valid gateway literal",
    )
  }
  ip
}
