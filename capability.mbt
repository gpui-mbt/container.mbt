///|
/// The transport adapters a `start` can resolve to (issue 0019).
/// `DirectDocker` is the default for `Runtime::Docker` (Docker Engine
/// API over the Unix socket); `DirectXpc` is the M2 Apple adapter —
/// every setting is `NotYetImplemented` until issues 0023–0032 land.
/// `CliDocker`/`CliApple` are the CLI adapters, reachable only through
/// the explicit `start_cli` selection — `start` never falls back to
/// them silently.
pub enum Adapter {
  DirectDocker
  DirectXpc
  CliDocker
  CliApple
}

///|
/// One row per `GenericImage` setting (0019). The matrix switch on this
/// enum is exhaustive: adding a variant without deciding every adapter
/// column fails `moon check --deny-warn`. `DynamicPort`/`SctpPort`
/// refine `Mappings`; `HealthcheckWait`/`ExitWait` refine
/// `ReadyConditions` — the splits exist so each rejected value is
/// decided by the matrix alone, not by scattered adapter checks.
pub enum Setting {
  Command
  Entrypoint
  ContainerName
  EnvVars
  Labels
  Mappings
  DynamicPort
  SctpPort
  Mounts
  ReadyWait
  HealthcheckWait
  ExitWait
  HttpWait
  WorkingDir
  User
  Network
  Platform
  ReadonlyRootfs
  StartupTimeout
  /// 0033: pre-start archive upload (PUT /containers/{id}/archive).
  CopyTo
  /// 0044: tmpfs size/mode mount options.
  TmpfsOptions
  /// 0045: explicit --hostname.
  Hostname
  /// 0045: --add-host / HostConfig.ExtraHosts entries.
  ExtraHosts
  /// 0046: privileged mode.
  Privileged
  /// 0046: cap_add / cap_drop entries.
  Capabilities
  /// 0046: shm size.
  ShmSize
  /// 0046: --init.
  Init
}

///|
/// Lowercase names for rejection messages — kept compatible with the
/// 0004 wording ("healthcheck", "exit", "host port", ...).
fn Setting::name(self : Setting) -> String {
  match self {
    Command => "command"
    Entrypoint => "entrypoint"
    ContainerName => "container name"
    EnvVars => "environment variable"
    Labels => "label"
    Mappings => "port mapping"
    DynamicPort => "dynamic host port"
    SctpPort => "SCTP port"
    Mounts => "mount"
    ReadyWait => "log/duration wait"
    HealthcheckWait => "healthcheck"
    ExitWait => "exit"
    HttpWait => "http wait"
    WorkingDir => "working dir"
    User => "user"
    Network => "network"
    Platform => "platform"
    ReadonlyRootfs => "read-only rootfs"
    StartupTimeout => "startup timeout"
    CopyTo => "copy-to"
    TmpfsOptions => "tmpfs options"
    Hostname => "hostname"
    ExtraHosts => "extra host"
    Privileged => "privileged"
    Capabilities => "capability add/drop"
    ShmSize => "shm size"
    Init => "init"
  }
}

///|
/// Display name for adapter-specific rejection messages.
fn Adapter::name(self : Adapter) -> String {
  match self {
    DirectDocker => "Docker Engine API"
    DirectXpc => "Apple Container XPC"
    CliDocker => "Docker CLI"
    CliApple => "Apple Container CLI"
  }
}

///|
/// Per-cell verdict (0019). `Rejected` carries the verbatim reason
/// (kept identical to the 0004 CLI preflight wording so existing
/// assertions hold); `NotYetImplemented` carries the tracking issue.
pub enum Support {
  Supported
  Rejected(String)
  NotYetImplemented(Int32)
}

///|
/// The single source of adapter capability truth (0019). Cells must not
/// mark a capability `Supported` that is merely untested — that is what
/// `Rejected`/`NotYetImplemented` are for.
pub fn capability(adapter : Adapter, setting : Setting) -> Support {
  match adapter {
    DirectXpc =>
      // M2 (issues 0023–0032) has not landed; nothing is supported yet.
      NotYetImplemented(23)
    DirectDocker =>
      match setting {
        Command
        | Entrypoint
        | ContainerName
        | EnvVars
        | Labels
        | Mappings
        | DynamicPort
        | SctpPort
        | Mounts
        | ReadyWait
        | HttpWait
        | HealthcheckWait
        | ExitWait
        | WorkingDir
        | User
        | Network
        | Platform
        | ReadonlyRootfs
        | StartupTimeout
        | CopyTo
        | TmpfsOptions
        | Hostname
        | ExtraHosts
        | Privileged
        | Capabilities
        | ShmSize
        | Init => Supported
      }
    CliDocker =>
      match setting {
        HealthcheckWait => NotYetImplemented(37)
        ExitWait => NotYetImplemented(38)
        HttpWait => NotYetImplemented(36)
        // docker cp is a CLI-binary path; the M1+ contract is
        // archive-API only, so CLI copy-to stays unimplemented.
        CopyTo => NotYetImplemented(33)
        Command
        | Entrypoint
        | ContainerName
        | EnvVars
        | Labels
        | Mappings
        | DynamicPort
        | SctpPort
        | Mounts
        | ReadyWait
        | WorkingDir
        | User
        | Network
        | Platform
        | ReadonlyRootfs
        | StartupTimeout
        | TmpfsOptions
        | Hostname
        | ExtraHosts
        | Privileged
        | Capabilities
        | ShmSize
        | Init => Supported
      }
    CliApple =>
      match setting {
        DynamicPort =>
          Rejected(
            "automatic host port assignment is not yet verified on Apple Container; use with_mapped_port",
          )
        SctpPort =>
          Rejected("SCTP port publishing is not supported on Apple container")
        Mounts => Rejected("--mount is not yet verified on Apple Container")
        Network => Rejected("--network is not yet verified on Apple Container")
        Platform =>
          Rejected("--platform is not yet verified on Apple Container")
        User => Rejected("--user is not yet verified on Apple Container")
        ReadonlyRootfs =>
          Rejected("--read-only is not yet verified on Apple Container")
        HealthcheckWait => NotYetImplemented(37)
        ExitWait => NotYetImplemented(38)
        HttpWait => NotYetImplemented(36)
        CopyTo => NotYetImplemented(33)
        // `container run --tmpfs` has no documented size/mode notation.
        TmpfsOptions =>
          Rejected(
            "tmpfs size/mode is not supported by the Apple container CLI",
          )
        // `container run` documents no --hostname/--add-host flags; the
        // upstream /etc/hosts exec fallback is XPC-only by design (0045).
        Hostname =>
          Rejected("--hostname is not supported by the Apple container CLI")
        ExtraHosts =>
          Rejected("--add-host is not supported by the Apple container CLI")
        // `container run` documents no --privileged/--cap-*/--shm-size/
        // --init flags (0046); XPC maps them on containerCreate (0026).
        Privileged =>
          Rejected(
            "privileged mode is not supported by the Apple container CLI",
          )
        Capabilities =>
          Rejected(
            "capability add/drop is not supported by the Apple container CLI",
          )
        ShmSize =>
          Rejected("shm size is not supported by the Apple container CLI")
        Init => Rejected("--init is not supported by the Apple container CLI")
        Command
        | Entrypoint
        | ContainerName
        | EnvVars
        | Labels
        | Mappings
        | ReadyWait
        | WorkingDir
        | StartupTimeout => Supported
      }
  }
}

///|
/// Which matrix rows a concrete `GenericImage` actually uses — only
/// non-default settings are checked, so a bare image never trips a
/// `Rejected` cell.
fn settings_in_use(image : GenericImage) -> Array[Setting] {
  let used : Array[Setting] = []
  if image.command.length() > 0 {
    used.push(Command)
  }
  if image.entrypoint is Some(_) {
    used.push(Entrypoint)
  }
  if image.container_name is Some(_) {
    used.push(ContainerName)
  }
  if image.env_vars.length() > 0 {
    used.push(EnvVars)
  }
  if image.labels.length() > 0 {
    used.push(Labels)
  }
  if image.mappings.length() > 0 {
    used.push(Mappings)
    for m in image.mappings {
      if m.host_port() == 0 {
        used.push(DynamicPort)
      }
      if m.container_port().protocol_name() == "sctp" {
        used.push(SctpPort)
      }
    }
  }
  if image.hostname is Some(_) {
    used.push(Hostname)
  }
  if image.privileged {
    used.push(Privileged)
  }
  if image.cap_add.length() > 0 || image.cap_drop.length() > 0 {
    used.push(Capabilities)
  }
  if image.shm_size_bytes is Some(_) {
    used.push(ShmSize)
  }
  if image.init {
    used.push(Init)
  }
  if image.extra_hosts.length() > 0 {
    used.push(ExtraHosts)
  }
  if image.mounts.length() > 0 {
    used.push(Mounts)
    for m in image.mounts {
      if m is Tmpfs(_, _, opts) &&
        (opts.size_bytes is Some(_) || opts.mode is Some(_)) {
        used.push(TmpfsOptions)
      }
    }
  }
  for ready in image.ready_conditions {
    match ready {
      Nothing | Millis(_) => used.push(ReadyWait)
      MessageOnStdout(_) | MessageOnStderr(_) | MessageOnEither(_) =>
        used.push(ReadyWait)
      Healthcheck => used.push(HealthcheckWait)
      Exit(_) => used.push(ExitWait)
      Http(_) => used.push(HttpWait)
    }
  }
  if image.working_dir is Some(_) {
    used.push(WorkingDir)
  }
  if image.user is Some(_) {
    used.push(User)
  }
  if image.network is Some(_) {
    used.push(Network)
  }
  if image.platform is Some(_) {
    used.push(Platform)
  }
  if image.healthcheck is Some(_) {
    used.push(HealthcheckWait)
  }
  if image.readonly_rootfs {
    used.push(ReadonlyRootfs)
  }
  if image.copy_to.length() > 0 {
    used.push(CopyTo)
  }
  if image.startup_timeout_ms != 60000 {
    used.push(StartupTimeout)
  }
  used
}

///|
/// The single preflight entry point (0019): every setting the image
/// uses is checked against the matrix BEFORE any daemon or CLI request
/// — a `Rejected`/`NotYetImplemented` verdict means zero side effects.
/// Value-level validation (names, duplicates, mount syntax) follows in
/// `validate_image_request`.
fn preflight(adapter : Adapter, image : GenericImage) -> Unit raise {
  for setting in settings_in_use(image) {
    match capability(adapter, setting) {
      Supported => ()
      Rejected(reason) =>
        fail("\{setting.name()} rejected on \{adapter.name()}: \{reason}")
      NotYetImplemented(issue) =>
        fail(
          "\{setting.name()} on \{adapter.name()} is not yet implemented (issue \{issue})",
        )
    }
  }
  validate_image_request(image)
}

///|
/// The adapter a `Runtime` resolves to for `start` (0019). `Docker` is
/// the direct Engine API; `AppleContainer` targets the M2 XPC adapter —
/// which reports `NotYetImplemented` until 0023+ land, so `start` on
/// Apple fails explicitly rather than silently using the CLI.
fn adapter_for(runtime : Runtime) -> Adapter {
  match runtime {
    Docker => DirectDocker
    AppleContainer => DirectXpc
  }
}

///|
/// The CLI adapter selected by `start_cli` — the only route that still
/// spawns `docker`/`container` processes (0019).
fn cli_adapter_for(runtime : Runtime) -> Adapter {
  match runtime {
    Docker => CliDocker
    AppleContainer => CliApple
  }
}

///|
/// Runtime capability check evaluated before any run/pull side effect.
/// Every request element is either applied to the command line or rejected
/// with an explicit error naming the setting, the runtime and the reason.
/// Settings that are not verified on a runtime are rejections, never silent
/// drops (upstream `linux_unsupported_request_reason` / `reject_sctp_ports` /
/// `reject_duplicate_mapped_ports` / `normalize_platform` parity).
/// Request-level validation shared by the CLI adapter and the direct
/// Engine API path (issue 0010): container name, duplicate published
/// ports, env/label keys, and mount arguments are rejected before any
/// side effect.
fn validate_image_request(image : GenericImage) -> Unit raise {
  guard image.startup_timeout_ms > 0 else { fail("invalid startup timeout") }
  if image.container_name is Some(name) {
    guard valid_container_name(name) else {
      fail("invalid container name: \{name}")
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
  if image.network is Some(name) {
    guard name != "" &&
      !name.iter().any(fn(c) { c is ' ' || c is '\n' || c is '\t' }) else {
      fail("invalid network name")
    }
  }
  for mount in image.mounts {
    let (kind, source, destination) = match mount {
      Bind(src, dst, _) => ("bind", src, dst)
      Volume(src, dst, _) => ("volume", src, dst)
      Tmpfs(dst, _, _) => ("tmpfs", "", dst)
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

///|
/// Runtime capability check evaluated before any run/pull side effect.
/// Every request element is either applied to the command line or rejected
/// with an explicit error naming the setting, the runtime and the reason.
/// Settings that are not verified on a runtime are rejections, never silent
/// drops (upstream `linux_unsupported_request_reason` / `reject_sctp_ports` /
/// `reject_duplicate_mapped_ports` / `normalize_platform` parity).
/// Since 0019 the per-setting verdicts live in the capability matrix —
/// this function is the CLI adapters' call site for `build_run_args`.
fn preflight_run(runtime : Runtime, image : GenericImage) -> Unit raise {
  preflight(cli_adapter_for(runtime), image)
}
