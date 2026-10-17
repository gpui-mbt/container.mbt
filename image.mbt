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
/// Deep-enough copy for the direct start path (0048): the attempt's
/// synthetic name and ownership label are applied to the copy so the
/// caller's builder is never mutated by `start_with_client`. Every
/// `with_*` field is carried; arrays are copied elementwise.
fn GenericImage::snapshot(self : GenericImage) -> GenericImage {
  {
    name: self.name,
    tag: self.tag,
    command: self.command.copy(),
    entrypoint: self.entrypoint,
    container_name: self.container_name,
    env_vars: self.env_vars.copy(),
    labels: self.labels.copy(),
    mappings: self.mappings.copy(),
    mounts: self.mounts.copy(),
    ready_conditions: self.ready_conditions.copy(),
    healthcheck: self.healthcheck,
    startup_timeout_ms: self.startup_timeout_ms,
    working_dir: self.working_dir,
    user: self.user,
    network: self.network,
    hostname: self.hostname,
    extra_hosts: self.extra_hosts.copy(),
    privileged: self.privileged,
    cap_add: self.cap_add.copy(),
    cap_drop: self.cap_drop.copy(),
    shm_size_bytes: self.shm_size_bytes,
    init: self.init,
    platform: self.platform,
    readonly_rootfs: self.readonly_rootfs,
    copy_to: self.copy_to.copy(),
    ssh: self.ssh,
    masked_paths: self.masked_paths,
    readonly_paths: self.readonly_paths,
    kernel: self.kernel,
  }
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
pub fn WaitFor::seconds(seconds : Int32) -> WaitFor raise {
  guard seconds >= 0 else { fail("wait duration must not be negative") }
  let ms = seconds.to_int64() * 1000L
  guard ms <= 2147483647L else {
    fail("wait duration overflows the millisecond timeout")
  }
  Millis(ms.to_int())
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
/// Extra /etc/hosts entry target (upstream `ExtraHost`, 0045).
/// `Addr` carries an IPv4/IPv6 literal; `HostGateway` serializes to
/// Docker's `host-gateway` special value.
pub enum ExtraHost {
  Addr(String)
  HostGateway
}

///|
/// A compact, MoonBit-owned equivalent of GenericImage and ContainerRequest.
pub struct GenericImage {
  mut name : String
  mut tag : String
  mut command : Array[String]
  mut entrypoint : String?
  mut container_name : String?
  mut env_vars : Array[(String, String)]
  mut labels : Array[(String, String)]
  mappings : Array[PortMapping]
  mounts : Array[Mount]
  mut ready_conditions : Array[WaitFor]
  mut healthcheck : Healthcheck?
  mut startup_timeout_ms : Int32
  mut working_dir : String?
  mut user : String?
  mut network : String?
  mut hostname : String?
  mut privileged : Bool
  cap_add : Array[String]
  cap_drop : Array[String]
  mut shm_size_bytes : Int64?
  mut init : Bool
  extra_hosts : Array[(String, ExtraHost)]
  mut platform : String?
  mut readonly_rootfs : Bool
  copy_to : Array[CopyTarget]
  mut ssh : Bool
  mut masked_paths : Array[String]?
  mut readonly_paths : Array[String]?
  mut kernel : String?
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
    hostname: None,
    privileged: false,
    cap_add: [],
    cap_drop: [],
    shm_size_bytes: None,
    init: false,
    extra_hosts: [],
    platform: None,
    readonly_rootfs: false,
    copy_to: [],
    ssh: false,
    masked_paths: None,
    readonly_paths: None,
    kernel: None,
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
/// Override the image name used by `descriptor()` (upstream request
/// `image_name` wins over the image's own name, 0048). Non-empty.
pub fn GenericImage::with_name(
  self : GenericImage,
  name : String,
) -> GenericImage raise {
  guard name != "" else { fail("image name must not be empty") }
  self.name = name
  self
}

///|
/// Override the image tag used by `descriptor()` (upstream request
/// `image_tag`, 0048). Non-empty.
pub fn GenericImage::with_tag(
  self : GenericImage,
  tag : String,
) -> GenericImage raise {
  guard tag != "" else { fail("image tag must not be empty") }
  self.tag = tag
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
/// Bulk label merge — per-key last-wins over existing entries, in
/// argument order (upstream `with_labels` extend, 0048).
pub fn GenericImage::with_labels(
  self : GenericImage,
  labels : Array[(String, String)],
) -> GenericImage {
  for (k, v) in labels {
    ignore(self.with_label(k, v))
  }
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
/// Replace the whole readiness list — last call wins (upstream
/// `with_ready_conditions`, 0048). Distinct from `with_wait_for`,
/// which accumulates one condition per call.
pub fn GenericImage::with_ready_conditions(
  self : GenericImage,
  conditions : Array[WaitFor],
) -> GenericImage {
  self.ready_conditions = conditions.copy()
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
/// Explicit container hostname (upstream `with_hostname`, 0045). There
/// is deliberately no container-name/ID fallback here — upstream falls
/// back through `networks[0].options.hostname` on Apple, but emitting
/// `--hostname` unconditionally would change existing containers'
/// visible identity, so only an explicit name is sent.
pub fn GenericImage::with_hostname(
  self : GenericImage,
  name : String,
) -> GenericImage raise {
  guard name != "" &&
    !name.iter().any(fn(c) { c is ' ' || c is '\n' || c is '\t' }) else {
    fail("invalid hostname: \{name}")
  }
  self.hostname = Some(name)
  self
}

///|
/// Extra /etc/hosts entry (upstream `with_host`, 0045). The key must be
/// a bare hostname (no whitespace/colon — `:` is the wire delimiter,
/// so keys must not contain it even though IPv6 values do). `Addr`
/// values are checked only for emptiness/whitespace: core has no IP
/// parser, and rejecting colons would break IPv6.
pub fn GenericImage::with_host(
  self : GenericImage,
  key : String,
  host : ExtraHost,
) -> GenericImage raise {
  guard key != "" &&
    !key.iter().any(fn(c) { c is ' ' || c is '\n' || c is '\t' || c == ':' }) else {
    fail("invalid extra-host key: \{key}")
  }
  if host is Addr(addr) {
    guard addr != "" &&
      !addr.iter().any(fn(c) { c is ' ' || c is '\n' || c is '\t' }) else {
      fail("invalid extra-host address: \{addr}")
    }
  }
  self.extra_hosts.push((key, host))
  self
}

///|
/// Privileged mode toggle — last call wins, `false` restores the
/// default (upstream `with_privileged`, 0046). Never implied by any
/// other option.
pub fn GenericImage::with_privileged(
  self : GenericImage,
  enabled : Bool,
) -> GenericImage {
  self.privileged = enabled
  self
}

///|
/// Accumulate a Linux capability grant (upstream `with_cap_add`, 0046).
/// The name must be non-empty `[A-Za-z0-9_]+` — upstream forwards the
/// raw string; we validate at set time so failures precede any pull.
pub fn GenericImage::with_cap_add(
  self : GenericImage,
  name : String,
) -> GenericImage raise {
  guard valid_capability_name(name) else {
    fail("invalid capability name: \{name}")
  }
  self.cap_add.push(name)
  self
}

///|
/// Accumulate a Linux capability drop (upstream `with_cap_drop`, 0046).
pub fn GenericImage::with_cap_drop(
  self : GenericImage,
  name : String,
) -> GenericImage raise {
  guard valid_capability_name(name) else {
    fail("invalid capability name: \{name}")
  }
  self.cap_drop.push(name)
  self
}

///|
/// `/dev/shm` size in bytes — last call wins (upstream `with_shm_size`
/// takes u64; negative values raise instead of being unreprentable).
pub fn GenericImage::with_shm_size(
  self : GenericImage,
  bytes : Int64,
) -> GenericImage raise {
  guard bytes >= 0 else { fail("shm size must not be negative") }
  self.shm_size_bytes = Some(bytes)
  self
}

///|
/// Run an init inside the container (upstream `with_init`, 0046).
pub fn GenericImage::with_init(self : GenericImage) -> GenericImage {
  self.init = true
  self
}

///|
/// Docker capability names: `SYS_ADMIN`, `CAP_NET_RAW`, bare
/// alnum+underscore (leading CAP_ optional upstream — the daemon
/// normalizes either form).
fn valid_capability_name(name : String) -> Bool {
  name.length() > 0 &&
  !name
  .iter()
  .any(fn(c) { !(c is ('A'..<='Z' | 'a'..<='z' | '0'..<='9' | '_')) })
}

///|
/// Convenience for `with_host(key, ExtraHost::Addr(addr))` (0045).
pub fn GenericImage::with_host_addr(
  self : GenericImage,
  key : String,
  addr : String,
) -> GenericImage raise {
  self.with_host(key, Addr(addr))
}

///|
/// Convenience for `with_host(key, ExtraHost::HostGateway)` (0045).
pub fn GenericImage::with_host_gateway(
  self : GenericImage,
  key : String,
) -> GenericImage raise {
  self.with_host(key, HostGateway)
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

///|
/// Enable SSH access for the container (Apple Container XPC only).
pub fn GenericImage::with_ssh(self : GenericImage) -> GenericImage {
  self.ssh = true
  self
}

///|
/// Replace the runtime's default masked paths. An empty array disables
/// the default mask; `None` (never calling this) keeps the runtime
/// default. Last call wins.
pub fn GenericImage::with_masked_paths(
  self : GenericImage,
  paths : Array[String],
) -> GenericImage {
  self.masked_paths = Some(paths.copy())
  self
}

///|
/// Replace the runtime's default read-only paths. Empty array and
/// never-called are distinct, matching upstream.
pub fn GenericImage::with_readonly_paths(
  self : GenericImage,
  paths : Array[String],
) -> GenericImage {
  self.readonly_paths = Some(paths.copy())
  self
}

///|
/// Use a custom kernel file instead of the default kernel. The path is
/// validated (absolute, UTF-8, regular file) before any pull/create.
pub fn GenericImage::with_kernel(
  self : GenericImage,
  path : String,
) -> GenericImage {
  self.kernel = Some(path)
  self
}
