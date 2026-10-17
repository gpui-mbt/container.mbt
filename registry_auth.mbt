///|
/// Docker registry static auth (issue 0016): read `auths` entries from
/// `DOCKER_AUTH_CONFIG` / `DOCKER_CONFIG/config.json` /
/// `~/.docker/config.json` and build the `X-Registry-Auth` header value
/// for pull/resolve requests. Credential helpers (`credsStore` /
/// `credHelpers`) are intentionally unsupported — a config that only
/// has helpers resolves to anonymous, matching upstream. Header values
/// and decoded credentials are never logged or embedded in errors.

///|
/// Docker Hub's canonical `auths` key — what `docker login` writes for
/// Hub credentials (upstream `DOCKER_HUB_AUTH_KEY`).
const DOCKER_HUB_AUTH_KEY = "https://index.docker.io/v1/"

///|
/// Which config source applies (upstream `load_config_json` ordering):
/// `DOCKER_AUTH_CONFIG` inline JSON wins; a non-empty `DOCKER_CONFIG`
/// points at `{dir}/config.json` with NO `~/.docker` fallback (docker
/// CLI semantics — an empty DOCKER_CONFIG counts as unset); otherwise
/// `~/.docker/config.json` is tried.
priv enum AuthSource {
  Inline(String)
  File(String)
  Anonymous
}

///|
fn select_auth_source(
  docker_auth_config~ : String?,
  docker_config~ : String?,
  home~ : String?,
) -> AuthSource {
  match docker_auth_config {
    Some(json) if json != "" => return Inline(json)
    _ => ()
  }
  match docker_config {
    Some(dir) if dir != "" => return File("\{dir}/config.json")
    _ => ()
  }
  match home {
    Some(dir) if dir != "" => File("\{dir}/.docker/config.json")
    _ => Anonymous
  }
}

///|
/// upstream `auths_key`: the `auths` key for `reference`. A leading
/// component that looks like a registry host (contains `.` or `:`, or
/// is `localhost`) is the key — except exactly `docker.io` /
/// `index.docker.io`, which normalize to the Docker Hub key (the only
/// two names normalized; `registry-1.docker.io` and port-qualified
/// `docker.io:5000` stay literal). References without a host component
/// (`alpine`, `library/nginx`) use the Hub key.
fn auths_key(reference : String) -> String {
  match reference.find("/") {
    Some(i) => {
      let first = reference[:i].to_owned()
      let host_like = first.contains(".") ||
        first.contains(":") ||
        first == "localhost"
      if host_like {
        if first == "docker.io" || first == "index.docker.io" {
          DOCKER_HUB_AUTH_KEY
        } else {
          first
        }
      } else {
        DOCKER_HUB_AUTH_KEY
      }
    }
    None => DOCKER_HUB_AUTH_KEY
  }
}

///|
/// `config_json` + `auths` key → `X-Registry-Auth` header value:
/// base64-encoded JSON. `identitytoken` wins when non-empty; otherwise
/// `auth` is base64-decoded and split on the first `:` into
/// username/password (`serveraddress` carries the resolved key). Any
/// failure — missing `auths`, key mismatch, bad base64, non-UTF-8,
/// missing `:` — resolves to `None` (anonymous), never an error that
/// could carry credentials.
fn extract_auth_entry(config_json : String, key : String) -> String? {
  let config = try @json.parse(config_json) catch {
    _ => return None
  } noraise {
    j => j
  }
  guard config is Object(root) &&
    root.get("auths") is Some(Object(auths)) &&
    auths.get(key) is Some(Object(entry)) else {
    return None
  }
  if entry.get("identitytoken") is Some(String(token)) && token != "" {
    let payload : Json = { "identitytoken": token }
    return Some(encode_auth_payload(payload))
  }
  guard entry.get("auth") is Some(String(auth)) && auth != "" else {
    return None
  }
  let decoded : Bytes = try @base64.decode(auth) catch {
    _ => return None
  } noraise {
    b => b
  }
  let creds = try @utf8.decode(decoded[:]) catch {
    _ => return None
  } noraise {
    s => s
  }
  guard creds.find(":") is Some(colon) else { return None }
  let payload : Json = {
    "username": creds[:colon].to_owned(),
    "password": creds[colon + 1:].to_owned(),
    "serveraddress": key,
  }
  Some(encode_auth_payload(payload))
}

///|
/// base64 the header JSON. `Json::stringify` escapes credentials
/// correctly (control characters, quotes) — safer than hand-rolled
/// escaping.
fn encode_auth_payload(payload : Json) -> String {
  @base64.encode(@utf8.encode(payload.stringify()))
}

///|
/// Read a config file's text; any failure (missing, unreadable,
/// non-UTF-8) is anonymous — the message is never surfaced.
async fn read_config_file(path : String) -> String? {
  try Some(@fs.read_file(path).text()) catch {
    _ => None
  } noraise {
    t => t
  }
}

///|
/// The process-environment loader: resolves the three sources in
/// upstream order and returns the config JSON text, or `None`.
async fn load_config_json() -> String? {
  match
    select_auth_source(
      docker_auth_config=@env.get_env_var("DOCKER_AUTH_CONFIG"),
      docker_config=@env.get_env_var("DOCKER_CONFIG"),
      home=@env.get_env_var("HOME"),
    ) {
    Inline(json) => Some(json)
    File(path) => read_config_file(path)
    Anonymous => None
  }
}

///|
/// `X-Registry-Auth` header value for `descriptor`, or `None` for
/// anonymous access. Loaded per request like upstream — config edits
/// between pulls take effect.
async fn registry_auth_header(descriptor : String) -> String? {
  let config = try load_config_json() catch {
    _ => None
  } noraise {
    c => c
  }
  match config {
    Some(json) => extract_auth_entry(json, auths_key(descriptor))
    None => None
  }
}

///|
/// `headers~` argument form of `registry_auth_header`.
async fn registry_auth_headers(descriptor : String) -> Array[(String, String)] {
  let header = try registry_auth_header(descriptor) catch {
    _ => None
  } noraise {
    h => h
  }
  match header {
    Some(value) => [("X-Registry-Auth", value)]
    None => []
  }
}
