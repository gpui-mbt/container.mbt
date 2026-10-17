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
/// Validate user input before an operation with side effects. The attempt
/// supplies the effective `--name` and the ownership label that lets a failed
/// run find and remove exactly the container it may have created.
pub fn build_run_args(
  runtime : Runtime,
  image : GenericImage,
  attempt~ : RunAttempt,
) -> Array[String] raise {
  // Why not let an unsupported or contradictory request reach the runtime:
  // every validation lives in the preflight table before a process spawns.
  preflight_run(runtime, image)
  let args : Array[String] = ["run", "--detach"]
  args.push("--name")
  args.push(attempt.name())
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
  if image.hostname is Some(hostname) {
    args.push("--hostname")
    args.push(hostname)
  }
  for (key, host) in image.extra_hosts {
    let value = match host {
      Addr(addr) => addr
      HostGateway => "host-gateway"
    }
    args.push("--add-host")
    args.push("\{key}:\{value}")
  }
  if image.privileged {
    args.push("--privileged")
  }
  for cap in image.cap_add {
    args.push("--cap-add")
    args.push(cap)
  }
  for cap in image.cap_drop {
    args.push("--cap-drop")
    args.push(cap)
  }
  if image.shm_size_bytes is Some(bytes) {
    args.push("--shm-size")
    args.push(bytes.to_string())
  }
  if image.init {
    args.push("--init")
  }
  if image.platform is Some(platform) {
    args.push("--platform")
    args.push(platform)
  }
  if image.readonly_rootfs {
    args.push("--read-only")
  }
  for (key, value) in image.env_vars {
    args.push("--env")
    args.push("\{key}=\{value}")
  }
  for (key, value) in image.labels {
    args.push("--label")
    args.push("\{key}=\{value}")
  }
  args.push("--label")
  args.push("\{OWNERSHIP_LABEL}=\{attempt.owner_id()}")
  for mapping in image.mappings {
    args.push("--publish")
    args.push(mapping.as_publish_argument())
  }
  for mount in image.mounts {
    let (kind, source, destination, is_read_only, tmpfs) = match mount {
      Bind(src, dst, ro) => ("bind", src, dst, ro is ReadOnly, None)
      Volume(src, dst, ro) => ("volume", src, dst, ro is ReadOnly, None)
      Tmpfs(dst, ro, opts) => ("tmpfs", "", dst, ro is ReadOnly, Some(opts))
    }
    let mut option = "type=\{kind},target=\{destination}"
    if kind != "tmpfs" {
      option = option + ",source=\{source}"
    } else if tmpfs is Some(opts) {
      if opts.size_bytes is Some(bytes) {
        option = option + ",tmpfs-size=\{bytes}"
      }
      if opts.mode is Some(mode) {
        option = option + ",tmpfs-mode=\{octal_string(mode)}"
      }
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
/// Octal rendering for `--mount tmpfs-mode=` (Docker parses it as an
/// octal permission string). Input is already validated non-negative.
fn octal_string(value : Int32) -> String {
  if value == 0 {
    return "0"
  }
  let digits : Array[Char] = []
  let mut v = value
  while v > 0 {
    digits.push(('0'.to_int() + v % 8).unsafe_to_char())
    v = v / 8
  }
  digits.rev_in_place()
  String::from_array(digits)
}

///|
/// `<runtime> network inspect <name>` — the 0045 existence preflight.
/// Docker and Apple CLIs share the subcommand shape; Apple never reaches
/// this because `Network` is rejected there.
pub fn build_network_inspect_args(
  runtime : Runtime,
  name : String,
) -> Array[String] {
  match runtime {
    Docker | AppleContainer => ["network", "inspect", name]
  }
}

///|
/// Grace normalization for `stop_with_timeout` (0041): `None` and
/// negative values mean the 30 s default; `Some(v)` (v >= 0) is used
/// verbatim — `0` is the immediate-kill path. We deliberately do NOT
/// adopt upstream's macOS negative → i32::MAX conversion; a CLI
/// adapter could block ~24 h on it.
fn normalize_stop_grace(value : Int32?) -> Int32 {
  match value {
    None => 30
    Some(v) => if v < 0 { 30 } else { v }
  }
}

///|
/// `docker stop -t <sec> <id>` / `container stop --time <sec> <id>`;
/// a normalized grace of 0 switches to the kill argv (upstream
/// `stop_with_timeout(Some(0))` → kill).
pub fn build_stop_args(
  runtime : Runtime,
  id : String,
  grace_seconds : Int32?,
) -> Array[String] {
  let sec = normalize_stop_grace(grace_seconds)
  if sec == 0 {
    return ["kill", id]
  }
  match runtime {
    Docker => ["stop", "-t", sec.to_string(), id]
    AppleContainer => ["stop", "--time", sec.to_string(), id]
  }
}

///|
/// Both CLI adapters expose `inspect <name>`; the cleanup path checks the raw
/// output for the ownership run identifier.
pub fn build_inspect_args(name : String) -> Array[String] {
  ["inspect", name]
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
