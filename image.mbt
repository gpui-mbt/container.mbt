///|
/// Mount access mode (upstream `AccessMode`, 0044). `with_read_only`
/// maps to `ReadOnly`; `ReadWrite` is the default.
pub enum AccessMode {
  ReadOnly
  ReadWrite
}

///|
/// tmpfs mount options (upstream `MountTmpfsOptions`, 0044). `mode` is
/// the raw permission-bit integer (e.g. `0o1777`); CLI serialization
/// renders it as octal, the Engine API carries it as a JSON number.
pub struct TmpfsOptions {
  size_bytes : Int64?
  mode : Int32?
}

///|
pub fn TmpfsOptions::new() -> TmpfsOptions {
  { size_bytes: None, mode: None, }
}

///|
/// Byte size, verbatim. Negative sizes raise (upstream panics).
pub fn TmpfsOptions::with_size_bytes(
  self : TmpfsOptions,
  bytes : Int64,
) -> TmpfsOptions raise {
  guard bytes >= 0 else { fail("tmpfs size must not be negative") }
  { size_bytes: Some(bytes), mode: self.mode, }
}

///|
/// Size with optional base-1000 suffix (`k`/`m`/`g`, upstream
/// `with_size`). Empty, signed, non-numeric and overflowing specs raise.
pub fn TmpfsOptions::with_size(
  self : TmpfsOptions,
  spec : String,
) -> TmpfsOptions raise {
  let mult : Int64 = if spec.has_suffix("k") || spec.has_suffix("K") {
    1000
  } else if spec.has_suffix("m") || spec.has_suffix("M") {
    1000000
  } else if spec.has_suffix("g") || spec.has_suffix("G") {
    1000000000
  } else {
    1
  }
  let digits : StringView = if mult == 1 {
    spec[:]
  } else {
    spec[:spec.length() - 1]
  }
  guard digits.length() > 0 else { fail("invalid tmpfs size: \{spec}") }
  // Int64::MAX_VALUE spelled out — importing moonbitlang/core/int64
  // for one constant is not worth the dependency edge.
  let max_int64 : Int64 = 9223372036854775807
  let mut n : Int64 = 0
  for c in digits {
    guard c is ('0'..<='9') else { fail("invalid tmpfs size: \{spec}") }
    let d = (c.to_int() - '0'.to_int()).to_int64()
    guard n <= (max_int64 - d) / 10 else {
      fail("tmpfs size overflow: \{spec}")
    }
    n = n * 10 + d
  }
  guard n <= max_int64 / mult else { fail("tmpfs size overflow: \{spec}") }
  { size_bytes: Some(n * mult), mode: self.mode, }
}

///|
/// Permission bits (e.g. `0o1777`). Negative modes raise.
pub fn TmpfsOptions::with_mode(
  self : TmpfsOptions,
  mode : Int32,
) -> TmpfsOptions raise {
  guard mode >= 0 else { fail("tmpfs mode must not be negative") }
  { size_bytes: self.size_bytes, mode: Some(mode), }
}

///|
/// Mount options shared by the adapters (0044: access mode + tmpfs
/// options added; `bind_mount`/`volume_mount`/`tmpfs_mount` keep their
/// signatures).
pub enum Mount {
  Bind(String, String, AccessMode)
  Volume(String, String, AccessMode)
  Tmpfs(String, AccessMode, TmpfsOptions)
}

///|
pub fn Mount::bind_mount(source : String, destination : String) -> Mount {
  Bind(source, destination, ReadWrite)
}

///|
pub fn Mount::volume_mount(source : String, destination : String) -> Mount {
  Volume(source, destination, ReadWrite)
}

///|
pub fn Mount::tmpfs_mount(destination : String) -> Mount {
  Tmpfs(destination, ReadWrite, TmpfsOptions::new())
}

///|
/// tmpfs mount carrying explicit options (0044).
pub fn Mount::tmpfs_mount_options(
  destination : String,
  options : TmpfsOptions,
) -> Mount {
  Tmpfs(destination, ReadWrite, options)
}

///|
pub fn Mount::with_read_only(self : Mount) -> Mount {
  match self {
    Bind(source, destination, _) => Bind(source, destination, ReadOnly)
    Volume(source, destination, _) => Volume(source, destination, ReadOnly)
    Tmpfs(destination, _, options) => Tmpfs(destination, ReadOnly, options)
  }
}

///|
/// tmpfs byte size. Silently ignored on non-tmpfs mounts, matching
/// upstream where `MountTmpfsOptions` is dropped at reflection time.
pub fn Mount::with_size_bytes(self : Mount, bytes : Int64) -> Mount raise {
  match self {
    Tmpfs(dst, mode, opts) => Tmpfs(dst, mode, opts.with_size_bytes(bytes))
    _ => self
  }
}

///|
/// tmpfs size with `k`/`m`/`g` suffix. Silently ignored on non-tmpfs.
pub fn Mount::with_size(self : Mount, spec : String) -> Mount raise {
  match self {
    Tmpfs(dst, mode, opts) => Tmpfs(dst, mode, opts.with_size(spec))
    _ => self
  }
}

///|
/// tmpfs permission bits. Silently ignored on non-tmpfs.
pub fn Mount::with_mode(self : Mount, mode : Int32) -> Mount raise {
  match self {
    Tmpfs(dst, m, opts) => Tmpfs(dst, m, opts.with_mode(mode))
    _ => self
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
  /// Exit wait: `Some(code)` verifies the container's exit code,
  /// `None` accepts any exit (upstream `WaitFor::exit` exit_code).
  Exit(Int32?)
  Http(HttpWaitStrategy)
}

///|
pub fn WaitFor::nothing() -> WaitFor {
  Nothing
}

///|
/// Build a millisecond wait from an environment variable read at call
/// time (upstream `WaitFor::millis_in_env_var`). Unset, empty,
/// non-numeric, negative, or out-of-range values produce `Nothing` —
/// not an error. Invalid env values become `Nothing` while a negative
/// literal `Millis` is rejected in `wait_ready_until`; that asymmetry
/// is upstream's.
pub fn WaitFor::millis_in_env_var(name : String) -> WaitFor {
  match wait_millis_from_env_value(@env.get_env_var(name)) {
    Some(ms) => Millis(ms)
    None => Nothing
  }
}

///|
/// Parse an env value into a millisecond count — the pure core of
/// `millis_in_env_var` (0039). `None` on unset/empty/non-numeric/
/// negative/out-of-range; leading/trailing whitespace is not trimmed
/// (upstream `str::parse` does not trim either).
fn wait_millis_from_env_value(value : String?) -> Int32? {
  guard value is Some(v) else { return None }
  guard v.length() > 0 else { return None }
  // Decimal parse — no sign, digits only; anything else is invalid.
  let mut n : Int64 = 0
  for c in v {
    guard c is ('0'..<='9') else { return None }
    n = n * 10 + (c.to_int() - '0'.to_int()).to_int64()
    if n > 2147483647L {
      return None
    }
  }
  Some(n.to_int())
}

///|
/// Explicitly request a healthcheck wait. CLI runtime adapters fail before launch.
pub fn WaitFor::healthcheck() -> WaitFor {
  Healthcheck
}

///|
/// Wait for container exit regardless of exit code.
pub fn WaitFor::when_exited() -> WaitFor {
  Exit(None)
}

///|
/// Wait for container exit and verify the exit code. A mismatch raises
/// an error naming the expected and actual codes.
pub fn WaitFor::exit_code(code : Int32) -> WaitFor {
  Exit(Some(code))
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
