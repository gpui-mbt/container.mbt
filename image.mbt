///|
/// Mount options shared by the two initial CLI adapters.
pub enum Mount {
  Bind(String, String, Bool)
  Volume(String, String, Bool)
  Tmpfs(String)
}

///|
pub fn Mount::bind_mount(source : String, destination : String) -> Mount {
  Bind(source, destination, false)
}

///|
pub fn Mount::volume_mount(source : String, destination : String) -> Mount {
  Volume(source, destination, false)
}

///|
pub fn Mount::tmpfs_mount(destination : String) -> Mount {
  Tmpfs(destination)
}

///|
pub fn Mount::with_read_only(self : Mount) -> Mount {
  match self {
    Bind(source, destination, _) => Bind(source, destination, true)
    Volume(source, destination, _) => Volume(source, destination, true)
    Tmpfs(destination) => Tmpfs(destination)
  }
}

///|
/// Readiness conditions retained from the upstream API. Unsupported conditions
/// are rejected before invoking the container runtime.
pub enum WaitFor {
  Nothing
  Millis(Int32)
  MessageOnStdout(String)
  MessageOnStderr(String)
  MessageOnEither(String)
  Healthcheck
  Exit
  Http(HttpWaitStrategy)
}

///|
pub fn WaitFor::nothing() -> WaitFor {
  Nothing
}

///|
/// Explicitly request a healthcheck wait. CLI runtime adapters fail before launch.
pub fn WaitFor::healthcheck() -> WaitFor {
  Healthcheck
}

///|
/// Explicitly request an exit wait. CLI runtime adapters fail before launch.
pub fn WaitFor::when_exited() -> WaitFor {
  Exit
}

///|
/// HTTP/1.1 readiness on a published port (issue 0036). Plain HTTP
/// only — TLS is intentionally unsupported and a TLS listener will
/// classify as a non-HTTP response until the deadline. CLI adapters
/// reject this before launch.
pub fn WaitFor::http(strategy : HttpWaitStrategy) -> WaitFor {
  Http(strategy)
}

///|
pub fn WaitFor::millis(milliseconds : Int32) -> WaitFor {
  Millis(milliseconds)
}

///|
pub fn WaitFor::seconds(seconds : Int32) -> WaitFor {
  Millis(seconds * 1000)
}

///|
pub fn WaitFor::message_on_stdout(message : String) -> WaitFor {
  MessageOnStdout(message)
}

///|
pub fn WaitFor::message_on_stderr(message : String) -> WaitFor {
  MessageOnStderr(message)
}

///|
pub fn WaitFor::message_on_either_std(message : String) -> WaitFor {
  MessageOnEither(message)
}

///|
/// A compact, MoonBit-owned equivalent of GenericImage and ContainerRequest.
pub struct GenericImage {
  name : String
  tag : String
  mut command : Array[String]
  mut entrypoint : String?
  mut container_name : String?
  mut env_vars : Array[(String, String)]
  mut labels : Array[(String, String)]
  mappings : Array[PortMapping]
  mounts : Array[Mount]
  ready_conditions : Array[WaitFor]
  mut healthcheck : Healthcheck?
  mut startup_timeout_ms : Int32
  mut working_dir : String?
  mut user : String?
  mut network : String?
  mut platform : String?
  mut readonly_rootfs : Bool
  copy_to : Array[CopyTarget]
}

///|
pub fn GenericImage::new(name : String, tag : String) -> GenericImage raise {
  guard name != "" && tag != "" else {
    fail("image name and tag must not be empty")
  }
  {
    name,
    tag,
    command: [],
    entrypoint: None,
    container_name: None,
    env_vars: [],
    labels: [],
    mappings: [],
    mounts: [],
    ready_conditions: [],
    healthcheck: None,
    startup_timeout_ms: 60000,
    working_dir: None,
    user: None,
    network: None,
    platform: None,
    readonly_rootfs: false,
    copy_to: [],
  }
}

///|
pub fn GenericImage::descriptor(self : GenericImage) -> String {
  "\{self.name}:\{self.tag}"
}

///|
pub fn GenericImage::with_cmd(
  self : GenericImage,
  command : Array[String],
) -> GenericImage {
  self.command = command.copy()
  self
}

///|
pub fn GenericImage::with_entrypoint(
  self : GenericImage,
  entrypoint : String,
) -> GenericImage {
  self.entrypoint = Some(entrypoint)
  self
}

///|
pub fn GenericImage::with_container_name(
  self : GenericImage,
  name : String,
) -> GenericImage {
  self.container_name = Some(name)
  self
}

///|
/// The most recent assignment to a key wins, matching upstream request overrides.
pub fn GenericImage::with_env_var(
  self : GenericImage,
  key : String,
  value : String,
) -> GenericImage {
  let vars : Array[(String, String)] = []
  for (k, v) in self.env_vars {
    if k != key {
      vars.push((k, v))
    }
  }
  vars.push((key, value))
  self.env_vars = vars
  self
}

///|
pub fn GenericImage::with_label(
  self : GenericImage,
  key : String,
  value : String,
) -> GenericImage {
  let labels : Array[(String, String)] = []
  for (k, v) in self.labels {
    if k != key {
      labels.push((k, v))
    }
  }
  labels.push((key, value))
  self.labels = labels
  self
}

///|
pub fn GenericImage::with_mapped_port(
  self : GenericImage,
  host_port : Int32,
  container_port : ContainerPort,
) -> GenericImage raise {
  self.mappings.push(PortMapping::new(host_port, container_port))
  self
}

///|
/// Docker supports automatic host-port assignment; Apple CLI parity is pending.
pub fn GenericImage::with_exposed_port(
  self : GenericImage,
  container_port : ContainerPort,
) -> GenericImage raise {
  self.mappings.push(PortMapping::new(0, container_port))
  self
}

///|
pub fn GenericImage::with_mount(
  self : GenericImage,
  mount : Mount,
) -> GenericImage {
  self.mounts.push(mount)
  self
}

///|
pub fn GenericImage::with_wait_for(
  self : GenericImage,
  ready : WaitFor,
) -> GenericImage {
  self.ready_conditions.push(ready)
  self
}

///|
pub fn GenericImage::with_startup_timeout(
  self : GenericImage,
  milliseconds : Int32,
) -> GenericImage raise {
  guard milliseconds > 0 else { fail("startup timeout must be positive") }
  self.startup_timeout_ms = milliseconds
  self
}

///|
pub fn GenericImage::with_working_dir(
  self : GenericImage,
  directory : String,
) -> GenericImage {
  self.working_dir = Some(directory)
  self
}

///|
pub fn GenericImage::with_user(
  self : GenericImage,
  user : String,
) -> GenericImage {
  self.user = Some(user)
  self
}

///|
pub fn GenericImage::with_network(
  self : GenericImage,
  name : String,
) -> GenericImage {
  self.network = Some(name)
  self
}

///|
pub fn GenericImage::with_platform(
  self : GenericImage,
  platform : String,
) -> GenericImage {
  self.platform = Some(platform)
  self
}

///|
pub fn GenericImage::with_readonly_rootfs(
  self : GenericImage,
  enabled : Bool,
) -> GenericImage {
  self.readonly_rootfs = enabled
  self
}

///|
pub fn GenericImage::ready_conditions(self : GenericImage) -> Array[WaitFor] {
  self.ready_conditions.copy()
}

///|
/// Return a snapshot, so callers cannot silently change the builder's ports.
pub fn GenericImage::mappings(self : GenericImage) -> Array[PortMapping] {
  self.mappings.copy()
}

///|
fn valid_container_name(name : String) -> Bool {
  guard name.length() >= 2 && name.length() <= 63 else { return false }
  for i = 0; i < name.length(); i = i + 1 {
    let c = name[i]
    let alnum = (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9')
    if !(alnum || (i > 0 && (c == '_' || c == '-' || c == '.'))) {
      return false
    }
  }
  true
}
