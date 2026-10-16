///|
/// Platform-specific commands are kept behind a pure argument builder.
pub(all) enum Runtime {
  Docker
  AppleContainer
}

///|
pub fn Runtime::executable(self : Runtime) -> String {
  match self {
    Docker => "docker"
    AppleContainer => "container"
  }
}

///|
/// Select Docker Engine on Linux and Apple Container on macOS.
pub async fn detect_runtime() -> Runtime {
  let (status, output) = @process.collect_stdout("uname", ["-s"])
  guard status == 0 else { fail("uname -s failed") }
  match output.text().trim() {
    "Linux" => Docker
    "Darwin" => AppleContainer
    os => fail("unsupported host OS: \{os}")
  }
}

///|
/// Validate user input before an operation with side effects.
pub fn build_run_args(runtime : Runtime, image : GenericImage) -> Array[String] raise {
  if image.container_name is Some(name) {
    guard valid_container_name(name) else {
      fail("invalid container name: must be 2..63 ASCII characters and begin with an alphanumeric")
    }
  }
  guard image.startup_timeout_ms > 0 else { fail("invalid startup timeout") }
  for condition in image.ready_conditions {
    match condition {
      Nothing | MessageOnStdout(_) | MessageOnStderr(_) | MessageOnEither(_) => ()
      Millis(ms) => if ms < 0 { fail("wait duration must not be negative") }
      Healthcheck | Exit => fail("healthcheck and exit waits are not yet supported by the CLI adapters")
    }
  }
  let args : Array[String] = ["run", "--detach"]
  if image.container_name is Some(name) {
    args.push("--name")
    args.push(name)
  }
  if image.entrypoint is Some(entrypoint) {
    args.push("--entrypoint")
    args.push(entrypoint)
  }
  if image.working_dir is Some(directory) {
    args.push("--workdir")
    args.push(directory)
  }
  if image.user is Some(user) {
    args.push("--user")
    args.push(user)
  }
  if image.network is Some(network) {
    args.push("--network")
    args.push(network)
  }
  if image.platform is Some(platform) {
    args.push("--platform")
    args.push(platform)
  }
  if image.readonly_rootfs {
    args.push("--read-only")
  }
  for (key, value) in image.env_vars {
    guard key != "" && !key.contains("=") else { fail("invalid environment key") }
    args.push("--env")
    args.push("\{key}=\{value}")
  }
  for (key, value) in image.labels {
    guard key != "" && !key.contains("=") else { fail("invalid label key") }
    args.push("--label")
    args.push("\{key}=\{value}")
  }
  let seen : Array[ContainerPort] = []
  for mapping in image.mappings {
    for prior in seen {
      guard !same_port(prior, mapping.container_port()) else {
        fail("duplicate published container port: \{prior.as_string()}")
      }
    }
    let port = mapping.container_port()
    if runtime is AppleContainer {
      guard mapping.host_port() != 0 else {
        fail("automatic host port assignment is not yet verified on Apple Container; use with_mapped_port")
      }
      guard port.protocol_name() != "sctp" else {
        fail("Apple Container does not support SCTP publication")
      }
    }
    seen.push(port)
    args.push("--publish")
    args.push(mapping.as_publish_argument())
  }
  for mount in image.mounts {
    let (kind, source, destination, is_read_only) = match mount {
      Bind(src, dst, ro) => ("bind", src, dst, ro)
      Volume(src, dst, ro) => ("volume", src, dst, ro)
      Tmpfs(dst) => ("tmpfs", "", dst, false)
    }
    guard destination.has_prefix("/") && !destination.contains(",") &&
      !destination.contains("=") else {
      fail("mount target must be an absolute path without commas or equals signs")
    }
    guard !source.contains(",") && !source.contains("=") else {
      fail("mount source cannot contain commas or equals signs")
    }
    let mut option = "type=\{kind},target=\{destination}"
    if kind != "tmpfs" {
      guard source != "" else { fail("mount source must not be empty") }
      if kind == "bind" {
        guard source.has_prefix("/") else { fail("bind source must be absolute") }
      }
      option = option + ",source=\{source}"
    }
    if is_read_only {
      option = option + ",readonly"
    }
    args.push("--mount")
    args.push(option)
  }
  args.push(image.descriptor())
  for part in image.command {
    args.push(part)
  }
  args
}

///|
pub fn build_stop_args(id : String) -> Array[String] {
  ["stop", id]
}

///|
pub fn build_remove_args(runtime : Runtime, id : String) -> Array[String] {
  match runtime {
    Docker => ["rm", "--force", id]
    AppleContainer => ["delete", "--force", id]
  }
}

///|
pub fn build_exec_args(id : String, command : Array[String]) -> Array[String] {
  let args : Array[String] = ["exec", id]
  for part in command {
    args.push(part)
  }
  args
}
