///|
/// Networks attached to a container, normalized from inspect's
/// `NetworkSettings.Networks`: network name → raw `IPAddress` value
/// (an empty string means attached but unassigned, e.g. host or
/// none networking).
pub struct ContainerNetworks {
  priv addrs : Map[String, String]
}

///|
pub fn ContainerNetworks::empty() -> ContainerNetworks {
  { addrs: {}, }
}

///|
/// Parse a `NetworkSettings.Networks` object tolerantly: entries whose
/// `IPAddress` is missing or not a string record as unassigned ("").
pub fn ContainerNetworks::parse(json : Json) -> ContainerNetworks {
  let addrs : Map[String, String] = Map([])
  match json {
    Object(m) =>
      for name, entry in m {
        match entry {
          Object(e) =>
            match e.get("IPAddress") {
              Some(String(ip)) => addrs[name] = ip
              _ => addrs[name] = ""
            }
          _ => addrs[name] = ""
        }
      }
    _ => ()
  }
  { addrs, }
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
