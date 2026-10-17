// JSON serialization for Apple Container XPC `containerCreate`
// (issue 0026, extended by 0030/0031/0047).

///|
fn j_obj(fields : Array[(String, Json)]) -> Json {
  Json::object(Map(fields))
}

///|
fn j_arr(items : Array[Json]) -> Json {
  Json::array(items)
}

///|
fn j_str(value : String) -> Json {
  Json::string(value)
}

///|
fn j_num(value : Double) -> Json {
  Json::number(value)
}

///|
fn j_int(value : Int) -> Json {
  Json::number(value.to_double())
}

///|
fn j_null() -> Json {
  Json::null()
}

///|
fn j_bool(value : Bool) -> Json {
  if value {
    Json::boolean(true)
  } else {
    Json::boolean(false)
  }
}

///|
fn j_str_array(values : Array[String]) -> Json {
  let items : Array[Json] = []
  for v in values {
    items.push(j_str(v))
  }
  j_arr(items)
}

///|
/// Upstream `normalize_platform`: returns `(architecture, rosetta,
/// resolve_platform)`; unallowed strings are treated as unspecified.
fn normalize_platform(platform : String?) -> (String, Bool, String?) {
  match platform {
    Some("linux/amd64" | "amd64") => ("amd64", true, Some("linux/amd64"))
    Some("linux/arm64" | "arm64") => ("arm64", false, Some("linux/arm64"))
    _ => ("arm64", false, None)
  }
}

///|
fn parse_process_user(user : String?) -> Json raise {
  let raw = match user {
    Some(u) if u != "" => u
    _ => return j_obj([("id", j_obj([("uid", j_int(0)), ("gid", j_int(0))]))])
  }
  let parts = raw.split(":").collect()
  let uid = parse_u32(parts[0])
  match uid {
    Some(uid) => {
      let gid = if parts.length() > 1 && parts[1] != "" {
        match parse_u32(parts[1]) {
          Some(g) => g
          None => raise XpcError::Malformed(detail="invalid gid in user string: \{raw}")
        }
      } else {
        0
      }
      j_obj([("id", j_obj([("uid", j_num(uid.to_double())), ("gid", j_num(gid.to_double()))]))])
    }
    None => j_obj([("raw", j_obj([("userString", j_str(raw))]))])
  }
}

///|
/// Minimal unsigned 32-bit parser (core `strconv` is not exported).
fn parse_u32(value : StringView) -> Int64? {
  guard value != "" else { return None }
  let mut n : Int64 = 0L
  for c in value {
    guard c is ('0'..<='9') else { return None }
    let d = (c.to_int() - '0'.to_int()).to_int64()
    n = n * 10L + d
    guard n <= 4294967295L else { return None }
  }
  Some(n)
}

///|
async fn allocate_free_host_port(port : ContainerPort) -> Int raise {
  let proto = port.protocol_name()
  let addr = @socket.Addr::parse("127.0.0.1:0")
  if proto == "udp" {
    let server = @socket.UdpServer::UdpServer(addr) catch {
      _ => raise XpcError::Malformed(detail="failed to allocate a free UDP host port")
    } noraise {
      s => s
    }
    let port = server.addr.port()
    server.close()
    port
  } else {
    let server = @socket.TcpServer::TcpServer(addr, reuse_addr=true) catch {
      _ => raise XpcError::Malformed(detail="failed to allocate a free TCP host port")
    } noraise {
      s => s
    }
    let port = server.addr.port()
    server.close()
    port
  }
}

///|
async fn unique_free_host_port(
  port : ContainerPort,
  allocated : Map[Int, Bool],
) -> Int raise {
  for i = 0; i < 64; i = i + 1 {
    let candidate = allocate_free_host_port(port)
    if !allocated.contains(candidate) {
      return candidate
    }
  }
  raise XpcError::Malformed(detail="could not allocate a unique free host port for \{port.as_string()}")
}

///|
/// Build the `publishedPorts` array. hostPort=0 (and expose) requests
/// are pre-allocated as the upstream macOS path does.
async fn build_ports(image : GenericImage) -> Array[Json] raise {
  let allocated : Map[Int, Bool] = Map([])
  let out : Array[Json] = []
  for mapping in image.mappings {
    let port = mapping.container_port()
    guard port.protocol_name() != "sctp" else {
      raise XpcError::Malformed(
        detail="SCTP port publishing is not supported on Apple container",
      )
    }
    let host_port = if mapping.host_port() == 0 {
      unique_free_host_port(port, allocated)
    } else {
      let fixed = mapping.host_port()
      if allocated.contains(fixed) {
        raise XpcError::Malformed(
          detail="duplicate host port mapping for container port \{port.as_string()}: host port \{fixed} is already mapped",
        )
      }
      fixed
    }
    allocated[host_port] = true
    out.push(
      j_obj([
        ("hostAddress", j_str("0.0.0.0")),
        ("hostPort", j_int(host_port)),
        ("containerPort", j_int(port.number())),
        ("proto", j_str(port.protocol_name())),
        ("count", j_int(1)),
      ]),
    )
  }
  out
}

///|
struct VolumeResolution {
  source : String
  format : String
}

///|
/// Create or inspect an Apple Container volume and return its backing
/// path/format. Automatically-created volumes intentionally survive a
/// failed start (same as Docker named-volume auto-creation).
pub async fn resolve_volume(name : String) -> VolumeResolution raise {
  guard name.length() <= 255 && name.length() > 0 else {
    raise XpcError::Malformed(detail="invalid volume name: \{name}")
  }
  let first = name[0]
  guard (first >= 'a' && first <= 'z') ||
    (first >= 'A' && first <= 'Z') ||
    (first >= '0' && first <= '9') else {
    raise XpcError::Malformed(detail="invalid volume name: \{name}")
  }
  for c in name {
    guard (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '_' || c == '.' || c == '-' else {
      raise XpcError::Malformed(detail="invalid volume name: \{name}")
    }
  }
  let create = try {
    send(
      service=XPC_SERVICE,
      route="volumeCreate",
      entries=[("volumeName", Str(name)), ("volumeDriver", Str("local"))],
    )
  } catch {
    XpcError::Remote(code~, message~) =>
      if message.contains("already exists") || message.contains("exists") {
        let reply = send(
          service=XPC_SERVICE,
          route="volumeInspect",
          entries=[("volumeName", Str(name))],
        )
        defer reply.close()
        reply.data("volume")
      } else {
        raise XpcError::Remote(code~, message~)
      }
    e => raise e
  } noraise {
    reply => {
      defer reply.close()
      reply.data("volume")
    }
  }
  let json = parse_json(create, "volume configuration")
  let source = match json {
    Object(map) =>
      match map.get("source") {
        Some(String(s)) => s
        _ => raise XpcError::Malformed(detail="volume configuration is missing source")
      }
    _ => raise XpcError::Malformed(detail="volume configuration is not an object")
  }
  let format = match json {
    Object(map) =>
      match map.get("format") {
        Some(String(s)) => s
        _ => raise XpcError::Malformed(detail="volume configuration is missing format")
      }
    _ => ""
  }
  { source, format, }
}

///|
async fn build_mounts(image : GenericImage) -> Array[Json] raise {
  let volumes : Map[String, VolumeResolution] = Map([])
  let out : Array[Json] = []
  for mount in image.mounts {
    match mount {
      Bind(source, destination, mode) => {
        guard source.has_prefix("/") else {
          raise XpcError::Malformed(detail="bind mount source must be absolute: \{source}")
        }
        guard destination.has_prefix("/") else {
          raise XpcError::Malformed(detail="mount destination must be absolute: \{destination}")
        }
        out.push(
          j_obj([
            ("type", j_obj([("virtiofs", j_obj([]))])),
            ("source", j_str(source)),
            ("destination", j_str(destination)),
            ("options", j_str_array([if mode is ReadOnly { "ro" } else { "rw" }])),
          ]),
        )
      }
      Volume(source, destination, mode) => {
        guard destination.has_prefix("/") else {
          raise XpcError::Malformed(detail="mount destination must be absolute: \{destination}")
        }
        let resolution = match volumes.get(source) {
          Some(r) => r
          None => {
            let r = resolve_volume(source)
            volumes[source] = r
            r
          }
        }
        out.push(
          j_obj([
            (
              "type",
              j_obj([
                (
                  "volume",
                  j_obj([
                    ("name", j_str(source)),
                    ("format", j_str(resolution.format)),
                    ("cache", j_obj([("on", j_obj([]))])),
                    ("sync", j_obj([("fsync", j_obj([]))])),
                  ]),
                ),
              ]),
            ),
            ("source", j_str(resolution.source)),
            ("destination", j_str(destination)),
            ("options", j_str_array([if mode is ReadOnly { "ro" } else { "rw" }])),
          ]),
        )
      }
      Tmpfs(destination, mode, options) => {
        guard destination.has_prefix("/") else {
          raise XpcError::Malformed(detail="mount destination must be absolute: \{destination}")
        }
        let opts : Array[String] = [if mode is ReadOnly { "ro" } else { "rw" }]
        if options.size_bytes is Some(size) {
          opts.push("size=\{size}")
        }
        if options.mode is Some(mode_bits) {
          opts.push("mode=\{octal_string(mode_bits)}")
        }
        out.push(
          j_obj([
            ("type", j_obj([("tmpfs", j_obj([]))])),
            ("source", j_str("tmpfs")),
            ("destination", j_str(destination)),
            ("options", j_str_array(opts)),
          ]),
        )
      }
    }
  }
  out
}

///|
fn build_labels(image : GenericImage) -> Json {
  let map : Map[String, Json] = Map([])
  for (key, value) in image.labels {
    map[key] = j_str(value)
  }
  j_obj(map.to_array())
}

///|
fn build_env(image : GenericImage) -> Array[String] {
  let out : Array[String] = []
  for (key, value) in image.env_vars {
    out.push("\{key}=\{value}")
  }
  out
}

///|
fn optional_strings(value : Array[String]?) -> Json {
  match value {
    Some(items) => j_str_array(items)
    None => j_null()
  }
}

///|
fn shm_size_json(value : Int64?) -> Json {
  match value {
    Some(v) => Json::number(v.to_double())
    None => j_null()
  }
}

///|
/// Build the `containerCreate` config JSON. The caller supplies the
/// attempt ID and the resolved image descriptor/config.
pub async fn build_container_config(
  image : GenericImage,
  id : String,
  descriptor_raw : String,
  image_config : ImageConfig,
) -> Json raise {
  let (exe, args) = effective_command(image_config, image.entrypoint, image.command)
  let (architecture, rosetta, _) = normalize_platform(image.platform)
  let hostname = match image.hostname {
    Some(h) => h
    None =>
      match image.container_name {
        Some(n) => n
        None => id
      }
  }
  let working_dir = image.working_dir.unwrap_or("/")
  let network = image.network.unwrap_or("default")
  let cap_add = if image.privileged {
    ["ALL"]
  } else {
    image.cap_add
  }
  let creation_date = @async.now().to_double() / 1000.0 - 978307200.0
  let mounts = build_mounts(image)
  let ports = build_ports(image)
  let init_process = j_obj([
    ("executable", j_str(exe)),
    ("arguments", j_str_array(args)),
    ("environment", j_str_array(build_env(image))),
    ("workingDirectory", j_str(working_dir)),
    ("terminal", j_bool(false)),
    ("user", parse_process_user(image.user)),
    ("supplementalGroups", j_arr([])),
    ("rlimits", j_arr([])),
  ])
  j_obj([
    ("id", j_str(id)),
    (
      "image",
      j_obj([("reference", j_str(normalize_image_reference(image.descriptor()))), ("descriptor", parse_json(@utf8.encode(descriptor_raw), "descriptor"))]),
    ),
    ("mounts", j_arr(mounts)),
    ("publishedPorts", j_arr(ports)),
    ("publishedSockets", j_arr([])),
    ("labels", build_labels(image)),
    ("sysctls", j_obj([])),
    (
      "networks",
      j_arr([
        j_obj([
          ("network", j_str(network)),
          ("options", j_obj([("hostname", j_str(hostname)), ("mtu", j_int(1280))])),
        ]),
      ]),
    ),
    ("dns", j_obj([("nameservers", j_arr([])), ("options", j_arr([])), ("searchDomains", j_arr([]))])),
    ("rosetta", j_bool(rosetta)),
    ("initProcess", init_process),
    ("platform", j_obj([("os", j_str("linux")), ("architecture", j_str(architecture)), ("variant", j_null())])),
    (
      "resources",
      j_obj([
        ("cpus", j_int(4)),
        ("memoryInBytes", j_int(1073741824)),
        ("storage", j_null()),
        ("cpuOverhead", j_int(1)),
      ]),
    ),
    ("runtimeHandler", j_str("container-runtime-linux")),
    ("virtualization", j_bool(false)),
    ("ssh", j_bool(image.ssh)),
    ("readOnly", j_bool(image.readonly_rootfs)),
    ("useInit", j_bool(image.init)),
    ("capAdd", j_str_array(cap_add)),
    ("capDrop", j_str_array(image.cap_drop)),
    ("shmSize", shm_size_json(image.shm_size_bytes)),
    ("maskedPaths", optional_strings(image.masked_paths)),
    ("readonlyPaths", optional_strings(image.readonly_paths)),
    ("stopSignal", j_null()),
    ("creationDate", Json::number(creation_date)),
  ])
}

///|
/// Build the containerization `Kernel` JSON used when `with_kernel` is
/// set. The default kernel path is a `file://` URL on the host.
pub fn kernel_json(path : String) -> Bytes {
  let json = j_obj([
    ("path", j_str("file://\{path}")),
    (
      "platform",
      j_obj([("os", j_str("linux")), ("architecture", j_str("arm64")), ("variant", j_null())]),
    ),
    (
      "commandLine",
      j_obj([
        ("kernelArgs", j_str_array(["console=hvc0", "tsc=reliable", "panic=0"])),
        ("initArgs", j_arr([])),
      ]),
    ),
  ])
  @utf8.encode(json.stringify())
}
