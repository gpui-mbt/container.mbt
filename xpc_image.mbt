// OCI image reference, descriptor, manifest and image-config resolution
// for the Apple Container XPC path (issue 0025).
//
// The daemon stores image descriptors as raw JSON and does not resolve
// the image's default CMD/ENTRYPOINT, so the client walks
// index -> manifest -> config through XPC `contentGet`.

///|
pub struct ImageConfig {
  entrypoint : Array[String]?
  cmd : Array[String]?
}

///|
fn json_string(obj : Json, key : String) -> String? {
  match obj {
    Object(map) =>
      match map.get(key) {
        Some(String(s)) => Some(s)
        _ => None
      }
    _ => None
  }
}

///|
fn parse_json(bytes : Bytes, what : String) -> Json raise {
  let text = try @utf8.decode(bytes) catch {
    _ => raise XpcError::Malformed(detail="\{what} is not UTF-8")
  } noraise {
    t => t
  }
  try @json.parse(text) catch {
    _ => raise XpcError::Malformed(detail="\{what} is not valid JSON")
  } noraise {
    j => j
  }
}

///|
/// Docker-style reference normalization: Apple's image service rejects a
/// bare `alpine:3.20` because it has no registry host.
pub fn normalize_image_reference(image : String) -> String {
  match image.find("/") {
    None => "docker.io/library/\{image}"
    Some(index) => {
      let first = image[:index]
      if first.contains(".") || first.contains(":") || first == "localhost" {
        image
      } else {
        "docker.io/\{image}"
      }
    }
  }
}

///|
async fn host_arch() -> String {
  let raw = try {
    let (status, output) = @process.collect_stdout("uname", ["-m"])
    if status == 0 {
      output.text().trim()
    } else {
      "arm64"
    }
  } catch {
    _ => "arm64"
  } noraise {
    s => s.to_owned()
  }
  if raw == "x86_64" || raw == "amd64" {
    "amd64"
  } else {
    "arm64"
  }
}

///|
/// Parsed `(os, architecture)` for an explicit platform string. Only
/// `linux/arm64` and `linux/amd64` are meaningful; anything else is
/// treated as unspecified, matching upstream `normalize_platform`.
fn parse_platform(platform : String?) -> (String, String)? {
  match platform {
    None => None
    Some(raw) => {
      let parts = raw.split("/").collect()
      if parts.length() == 2 && parts[0] == "linux" {
        let arch = match parts[1] {
          "amd64" | "x86_64" => "amd64"
          "arm64" | "aarch64" => "arm64"
          _ => return None
        }
        Some((parts[0].to_owned(), arch))
      } else {
        None
      }
    }
  }
}

///|
/// Select the manifest digest for the requested platform. Explicit
/// platforms never fall back; unspecified platforms prefer arm64, then
/// amd64, then an OS-only match, then the first non-attestation entry.
async fn select_manifest_digest(index_bytes : Bytes, platform : String?) -> String raise {
  let index = parse_json(index_bytes, "image index")
  let manifests = match index {
    Object(map) =>
      match map.get("manifests") {
        Some(Array(items)) => items
        _ => raise XpcError::Malformed(detail="image index has no manifests array")
      }
    _ => raise XpcError::Malformed(detail="image index is not an object")
  }
  let explicit = parse_platform(platform)
  let target = match explicit {
    Some((os, arch)) => (os, arch)
    None => ("linux", host_arch())
  }
  let mut os_only : String? = None
  let mut first_non_attestation : String? = None
  let mut arm64_fallback : String? = None
  let mut amd64_fallback : String? = None
  for item in manifests {
    let digest = match item {
      Object(map) =>
        match map.get("digest") {
          Some(String(d)) => d
          _ => continue
        }
      _ => continue
    }
    let p = match item {
      Object(map) =>
        match map.get("platform") {
          Some(Object(pl)) => Some(pl)
          _ => None
        }
      _ => None
    }
    let os = match p {
      Some(pl) =>
        match pl.get("os") {
          Some(String(s)) => s
          _ => ""
        }
      None => ""
    }
    let arch = match p {
      Some(pl) =>
        match pl.get("architecture") {
          Some(String(s)) => s
          _ => ""
        }
      None => ""
    }
    if explicit is Some(_) {
      if os == target.0 && arch == target.1 {
        return digest
      }
      continue
    }
    if os == "linux" && arch == "arm64" && arm64_fallback is None {
      arm64_fallback = Some(digest)
    }
    if os == "linux" && arch == "amd64" && amd64_fallback is None {
      amd64_fallback = Some(digest)
    }
    if os == "linux" && arch != "unknown" && os_only is None {
      os_only = Some(digest)
    }
    if arch != "unknown" && first_non_attestation is None {
      first_non_attestation = Some(digest)
    }
  }
  match explicit {
    Some((os, arch)) =>
      raise XpcError::Malformed(
        detail="no matching manifest for \{os}/\{arch}",
      )
    None => {
      match arm64_fallback {
        Some(d) => d
        None =>
          match amd64_fallback {
            Some(d) => d
            None =>
              match os_only {
                Some(d) => d
                None =>
                  match first_non_attestation {
                    Some(d) => d
                    None => raise XpcError::Malformed(detail="image index has no usable manifest")
                  }
              }
          }
      }
    }
  }
}

///|
fn config_digest_from_manifest(manifest_bytes : Bytes) -> String raise {
  let manifest = parse_json(manifest_bytes, "image manifest")
  match manifest {
    Object(map) =>
      match map.get("config") {
        Some(Object(config)) =>
          match config.get("digest") {
            Some(String(d)) => d
            _ => raise XpcError::Malformed(detail="image manifest has no config digest")
          }
        _ => raise XpcError::Malformed(detail="image manifest has no config object")
      }
    _ => raise XpcError::Malformed(detail="image manifest is not an object")
  }
}

///|
fn parse_image_config(config_bytes : Bytes) -> ImageConfig raise {
  let root = parse_json(config_bytes, "image config")
  let config = match root {
    Object(map) =>
      match map.get("config") {
        Some(Object(c)) => c
        _ => raise XpcError::Malformed(detail="image config has no config object")
      }
    _ => raise XpcError::Malformed(detail="image config is not an object")
  }
  let entrypoint = match config.get("Entrypoint") {
    Some(Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          String(s) => out.push(s)
          _ => raise XpcError::Malformed(detail="image Entrypoint is not an array of strings")
        }
      }
      Some(out)
    }
    Some(Null) | None => None
    _ => raise XpcError::Malformed(detail="image Entrypoint has an unexpected type")
  }
  let cmd = match config.get("Cmd") {
    Some(Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          String(s) => out.push(s)
          _ => raise XpcError::Malformed(detail="image Cmd is not an array of strings")
        }
      }
      Some(out)
    }
    Some(Null) | None => None
    _ => raise XpcError::Malformed(detail="image Cmd has an unexpected type")
  }
  { entrypoint, cmd, }
}

///|
pub async fn content_get(digest : String) -> Bytes raise {
  let reply = send(
    service=XPC_IMAGE_SERVICE,
    route="contentGet",
    entries=[("digest", Str(digest))],
  )
  defer reply.close()
  let path = reply.string("contentPath")
  let data = try @fs.read_file(path) catch {
    _ => raise XpcError::Malformed(detail="failed to read content for \{digest}")
  } noraise {
    d => d
  }
  data.binary()
}

///|
/// Resolve the image's default CMD/ENTRYPOINT via the OCI content store.
pub async fn resolve_image_config(descriptor_raw : String, platform : String?) -> ImageConfig raise {
  let descriptor = parse_json(@utf8.encode(descriptor_raw), "descriptor")
  let (media_type, digest) = match descriptor {
    Object(_) =>
      (
        json_string(descriptor, "mediaType").unwrap_or(""),
        json_string(descriptor, "digest").unwrap_or(""),
      )
    _ => raise XpcError::Malformed(detail="descriptor is not an object")
  }
  guard media_type != "" && digest != "" else {
    raise XpcError::Malformed(detail="descriptor is missing mediaType/digest")
  }
  let config_digest = if media_type == "application/vnd.oci.image.index.v1+json" ||
    media_type == "application/vnd.docker.distribution.manifest.list.v2+json" {
    let index = content_get(digest)
    let manifest_digest = select_manifest_digest(index, platform)
    config_digest_from_manifest(content_get(manifest_digest))
  } else if media_type == "application/vnd.oci.image.manifest.v1+json" ||
    media_type == "application/vnd.docker.distribution.manifest.v2+json" {
    config_digest_from_manifest(content_get(digest))
  } else if media_type == "application/vnd.oci.image.config.v1+json" {
    digest
  } else {
    raise XpcError::Malformed(detail="unsupported image mediaType: \{media_type}")
  }
  parse_image_config(content_get(config_digest))
}

///|
/// Resolve CMD/ENTRYPOINT with Docker's override semantics.
pub fn effective_command(
  config : ImageConfig,
  entrypoint_override : String?,
  cmd_override : Array[String],
) -> (String, Array[String]) raise {
  let entrypoint : Array[String]? = match entrypoint_override {
    Some("") => None
    Some(ep) => Some([ep])
    None => config.entrypoint
  }
  let entrypoint = match entrypoint {
    Some(ep) =>
      if ep.length() == 1 && ep[0] == "" {
        None
      } else {
        Some(ep)
      }
    None => None
  }
  let cmd : Array[String]? = if cmd_override.length() > 0 {
    Some(cmd_override)
  } else {
    config.cmd
  }
  match (entrypoint, cmd) {
    (Some(ep), Some(args)) if ep.length() > 0 && args.length() > 0 => {
      let combined = ep.copy()
      combined.append(args)
      let exe = combined[0]
      (exe, combined[1:].to_owned())
    }
    (Some(ep), _) if ep.length() > 0 => {
      let exe = ep[0]
      (exe, ep[1:].to_owned())
    }
    (_, Some(args)) if args.length() > 0 => {
      let exe = args[0]
      (exe, args[1:].to_owned())
    }
    _ => raise XpcError::Malformed(detail="no command specified: the image has no CMD/ENTRYPOINT and none was provided")
  }
}

///|
/// Pull an image (normalized reference), optionally with an OCI platform.
pub async fn pull_image(image : String, platform_arch : String?) -> Unit raise {
  let normalized = normalize_image_reference(image)
  let entries : Array[(String, XpcValue)] = [
    ("imageReference", Str(normalized)),
    ("insecureFlag", Bool(false)),
    ("maxConcurrentDownloads", Int64(3)),
  ]
  if platform_arch is Some(arch) {
    entries.push(("ociPlatform", Data(@utf8.encode("{\"os\":\"linux\",\"architecture\":\"\{arch}\"}"))))
  }
  let reply = send(
    service=XPC_IMAGE_SERVICE,
    route="imagePull",
    entries~,
    timeout_ms=XPC_LONG_TIMEOUT_MS,
  )
  reply.close()
}

///|
/// `imageList` -> `(reference, descriptor raw JSON)` pairs.
pub async fn list_images() -> Array[(String, String)] raise {
  let reply = send(service=XPC_IMAGE_SERVICE, route="imageList", timeout_ms=10000)
  defer reply.close()
  let data = reply.data("imageDescriptions")
  let json = parse_json(data, "imageDescriptions")
  let out : Array[(String, String)] = []
  match json {
    Array(items) =>
      for item in items {
        match item {
          Object(map) => {
            let reference = match map.get("reference") {
              Some(String(s)) => s
              _ => ""
            }
            let descriptor = match map.get("descriptor") {
              Some(d) => d
              _ => continue
            }
            if reference != "" {
              out.push((reference, descriptor.stringify()))
            }
          }
          _ => ()
        }
      }
    _ => raise XpcError::Malformed(detail="imageDescriptions is not an array")
  }
  out
}

///|
/// Resolve or pull the image and return its descriptor raw JSON.
pub async fn resolve_or_pull(image : String, platform : String?) -> String raise {
  let normalized = normalize_image_reference(image)
  let explicit_arch = match parse_platform(platform) {
    Some((_, arch)) => Some(arch)
    None => None
  }
  if explicit_arch is Some(arch) && arch == "amd64" {
    pull_image(image, Some(arch))
  }
  let found = list_images()
  let mut descriptor : String? = None
  for (reference, raw) in found {
    if reference == normalized || reference == image {
      descriptor = Some(raw)
      break
    }
  }
  match descriptor {
    Some(raw) => raw
    None => {
      pull_image(image, explicit_arch)
      let after = list_images()
      for (reference, raw) in after {
        if reference == normalized || reference == image {
          return raw
        }
      }
      raise XpcError::Remote(code="imageNotFound", message="image not found: \{normalized}")
    }
  }
}
