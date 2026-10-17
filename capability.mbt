///|
/// Human-readable runtime name used in preflight rejection messages.
fn Runtime::display_name(self : Runtime) -> String {
  match self {
    Docker => "Docker"
    AppleContainer => "Apple Container"
  }
}

///|
/// Runtime capability check evaluated before any run/pull side effect.
/// Every request element is either applied to the command line or rejected
/// with an explicit error naming the setting, the runtime and the reason.
/// Settings that are not verified on a runtime are rejections, never silent
/// drops (upstream `linux_unsupported_request_reason` / `reject_sctp_ports` /
/// `reject_duplicate_mapped_ports` / `normalize_platform` parity).
fn preflight_run(runtime : Runtime, image : GenericImage) -> Unit raise {
  guard image.startup_timeout_ms > 0 else { fail("invalid startup timeout") }
  for condition in image.ready_conditions {
    match condition {
      Nothing | MessageOnStdout(_) | MessageOnStderr(_) | MessageOnEither(_) =>
        ()
      Millis(ms) => if ms < 0 { fail("wait duration must not be negative") }
      Healthcheck | Exit =>
        fail(
          "healthcheck and exit waits are not supported by the \{runtime.display_name()} CLI adapter",
        )
    }
  }
  if runtime is AppleContainer {
    // Apple Container CLI parity for these flags is unverified; they are
    // rejected here until `container run` support is confirmed on hardware.
    if image.network is Some(_) {
      fail("--network is not yet verified on Apple Container")
    }
    if image.platform is Some(_) {
      fail("--platform is not yet verified on Apple Container")
    }
    if image.user is Some(_) {
      fail("--user is not yet verified on Apple Container")
    }
    if image.mounts.length() > 0 {
      fail("--mount is not yet verified on Apple Container")
    }
    if image.readonly_rootfs {
      fail("--read-only is not yet verified on Apple Container")
    }
  }
  let seen_container : Array[ContainerPort] = []
  let seen_host : Array[(Int32, String)] = []
  for mapping in image.mappings {
    let port = mapping.container_port()
    for prior in seen_container {
      guard !same_port(prior, port) else {
        fail("duplicate published container port: \{prior.as_string()}")
      }
    }
    let host = mapping.host_port()
    if host != 0 {
      for (prior_port, prior_proto) in seen_host {
        guard !(prior_port == host && prior_proto == port.protocol_name()) else {
          fail("duplicate published host port: \{host}/\{port.protocol_name()}")
        }
      }
      seen_host.push((host, port.protocol_name()))
    }
    if runtime is AppleContainer {
      guard host != 0 else {
        fail(
          "automatic host port assignment is not yet verified on Apple Container; use with_mapped_port",
        )
      }
      guard port.protocol_name() != "sctp" else {
        fail("SCTP port publishing is not supported on Apple container")
      }
    }
    seen_container.push(port)
  }
  for (key, _) in image.env_vars {
    guard key != "" && !key.contains("=") else {
      fail("invalid environment key")
    }
  }
  for (key, _) in image.labels {
    guard key != "" && !key.contains("=") else { fail("invalid label key") }
  }
  for mount in image.mounts {
    let (kind, source, destination) = match mount {
      Bind(src, dst, _) => ("bind", src, dst)
      Volume(src, dst, _) => ("volume", src, dst)
      Tmpfs(dst) => ("tmpfs", "", dst)
    }
    guard destination.has_prefix("/") &&
      !destination.contains(",") &&
      !destination.contains("=") else {
      fail(
        "mount target must be an absolute path without commas or equals signs",
      )
    }
    guard !source.contains(",") && !source.contains("=") else {
      fail("mount source cannot contain commas or equals signs")
    }
    if kind != "tmpfs" {
      guard source != "" else { fail("mount source must not be empty") }
      if kind == "bind" {
        guard source.has_prefix("/") else {
          fail("bind source must be absolute")
        }
      }
    }
  }
}
