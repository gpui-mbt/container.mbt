///|
/// Issue 0016 fixtures. All credentials are dummy values; none may
/// appear in test output other than through the assertions themselves.
const DUMMY_B64 : String = "dXNlcjpwYXNz" // base64("user:pass")

///|
fn b64(s : String) -> String {
  @base64.encode(@utf8.encode(s))
}

///|
test "auths_key normalizes docker.io spellings to the Hub key" {
  assert_eq(auths_key("alpine:latest"), "https://index.docker.io/v1/")
  assert_eq(auths_key("library/nginx"), "https://index.docker.io/v1/")
  assert_eq(auths_key("docker.io/org/private"), "https://index.docker.io/v1/")
  assert_eq(
    auths_key("index.docker.io/org/private"),
    "https://index.docker.io/v1/",
  )
  assert_eq(
    auths_key("docker.io/library/nginx:latest"),
    "https://index.docker.io/v1/",
  )
}

///|
test "auths_key keeps real registry hosts literal" {
  assert_eq(auths_key("ghcr.io/org/app:tag"), "ghcr.io")
  assert_eq(auths_key("localhost:5000/myimage"), "localhost:5000")
  assert_eq(auths_key("registry.example.com/img"), "registry.example.com")
  // NOT normalized: only bare docker.io / index.docker.io are.
  assert_eq(auths_key("registry-1.docker.io/org/img"), "registry-1.docker.io")
  assert_eq(auths_key("docker.io:5000/img"), "docker.io:5000")
  // A non-host first component still means Docker Hub.
  assert_eq(auths_key("org/img"), "https://index.docker.io/v1/")
}

///|
test "source priority: DOCKER_AUTH_CONFIG > DOCKER_CONFIG > HOME" {
  match
    select_auth_source(
      docker_auth_config=Some("{\"auths\":{}}"),
      docker_config=Some("/x"),
      home=Some("/h"),
    ) {
    Inline(j) => assert_eq(j, "{\"auths\":{}}")
    _ => fail("expected Inline")
  }
  // Empty DOCKER_AUTH_CONFIG falls through to DOCKER_CONFIG.
  match
    select_auth_source(
      docker_auth_config=Some(""),
      docker_config=Some("/x"),
      home=Some("/h"),
    ) {
    File(p) => assert_eq(p, "/x/config.json")
    _ => fail("expected File for DOCKER_CONFIG")
  }
  // Empty DOCKER_CONFIG is unset → HOME.
  match
    select_auth_source(
      docker_auth_config=None,
      docker_config=Some(""),
      home=Some("/h"),
    ) {
    File(p) => assert_eq(p, "/h/.docker/config.json")
    _ => fail("expected File for HOME")
  }
  // DOCKER_CONFIG set: even a missing file must NOT fall back to HOME —
  // the source selection returns File unconditionally and the read
  // failure yields anonymous (verified in the async loader test).
  match
    select_auth_source(
      docker_auth_config=None,
      docker_config=Some("/x"),
      home=Some("/h"),
    ) {
    File(p) => assert_eq(p, "/x/config.json")
    _ => fail("DOCKER_CONFIG must suppress the HOME fallback")
  }
  match
    select_auth_source(docker_auth_config=None, docker_config=None, home=None) {
    Anonymous => ()
    _ => fail("expected Anonymous")
  }
}

///|
test "identitytoken wins over auth" {
  let config = "{\"auths\":{\"https://index.docker.io/v1/\":{\"identitytoken\":\"tok123\",\"auth\":\"\{DUMMY_B64}\"}}}"
  let header = extract_auth_entry(config, "https://index.docker.io/v1/")
  match header {
    Some(h) => {
      let decoded = @utf8.decode(@base64.decode(h)[:])
      assert_true(decoded.contains("\"identitytoken\":\"tok123\""))
      assert_true(!decoded.contains("username"))
    }
    None => fail("expected a header")
  }
}

///|
test "auth decodes to username/password/serveraddress" {
  let creds = b64("u:p")
  let config = "{\"auths\":{\"ghcr.io\":{\"auth\":\"\{creds}\"}}}"
  let header = extract_auth_entry(config, "ghcr.io")
  match header {
    Some(h) => {
      let decoded = @utf8.decode(@base64.decode(h)[:])
      assert_true(decoded.contains("\"username\":\"u\""))
      assert_true(decoded.contains("\"password\":\"p\""))
      assert_true(decoded.contains("\"serveraddress\":\"ghcr.io\""))
    }
    None => fail("expected a header")
  }
}

///|
test "passwords may contain colons; quotes and control chars escape" {
  let creds = b64("u:p:a:ss")
  let config = "{\"auths\":{\"ghcr.io\":{\"auth\":\"\{creds}\"}}}"
  let header = extract_auth_entry(config, "ghcr.io")
  match header {
    Some(h) => {
      let decoded = @utf8.decode(@base64.decode(h)[:])
      assert_true(decoded.contains("\"password\":\"p:a:ss\""))
    }
    None => fail("expected a header")
  }
  let tricky_creds = b64("u\"x:p\u0001y")
  let tricky = "{\"auths\":{\"ghcr.io\":{\"auth\":\"\{tricky_creds}\"}}}"
  let header2 = extract_auth_entry(tricky, "ghcr.io")
  match header2 {
    Some(h) => {
      // Decoded payload must still be valid JSON (escaping worked).
      let json = @json.parse(@utf8.decode(@base64.decode(h)[:]))
      guard json is Object(m) else { fail("payload not an object") }
      match m.get("username") {
        Some(String(s)) => assert_eq(s, "u\"x")
        _ => fail("username not a string")
      }
      match m.get("password") {
        Some(String(s)) => assert_eq(s, "p\u0001y")
        _ => fail("password not a string")
      }
    }
    None => fail("expected a header")
  }
}

///|
test "missing/mismatched/malformed auth resolves to anonymous" {
  // No auths at all.
  assert_true(extract_auth_entry("{}", "k") is None)
  // Key mismatch.
  assert_true(
    extract_auth_entry(
      "{\"auths\":{\"other.io\":{\"auth\":\"\{DUMMY_B64}\"}}}",
      "ghcr.io",
    )
    is None,
  )
  // Bad base64.
  assert_true(
    extract_auth_entry(
      "{\"auths\":{\"ghcr.io\":{\"auth\":\"!!!not-base64\"}}}", "ghcr.io",
    )
    is None,
  )
  // Empty auth.
  assert_true(
    extract_auth_entry("{\"auths\":{\"ghcr.io\":{\"auth\":\"\"}}}", "ghcr.io")
    is None,
  )
  // No colon in decoded credentials.
  let nocolon = b64("nocolon")
  assert_true(
    extract_auth_entry(
      "{\"auths\":{\"ghcr.io\":{\"auth\":\"\{nocolon}\"}}}",
      "ghcr.io",
    )
    is None,
  )
  // Empty identitytoken falls back to auth (and auth absent → None).
  assert_true(
    extract_auth_entry(
      "{\"auths\":{\"ghcr.io\":{\"identitytoken\":\"\"}}}", "ghcr.io",
    )
    is None,
  )
  // Not JSON at all.
  assert_true(extract_auth_entry("not json", "k") is None)
  // credHelpers-only config: helpers are not consulted → anonymous.
  assert_true(
    extract_auth_entry(
      "{\"credHelpers\":{\"ghcr.io\":\"helper\"},\"credsStore\":\"desktop\"}", "ghcr.io",
    )
    is None,
  )
}

///|
async test "async loader honors DOCKER_AUTH_CONFIG and no-fallback rules" {
  let dir = @fs.tmpdir(prefix="container-mbt-auth")
  let docker_config_dir = "\{dir}/dc"
  let home = "\{dir}/home"
  @fs.mkdir(docker_config_dir, recursive=true)
  @fs.mkdir("\{home}/.docker", recursive=true)
  // HOME has a config; DOCKER_CONFIG points at an EMPTY dir → anonymous.
  @fs.write_file(
    "\{home}/.docker/config.json",
    "{\"auths\":{\"ghcr.io\":{\"auth\":\"\{DUMMY_B64}\"}}}",
  )
  let prev_auth = @env.get_env_var("DOCKER_AUTH_CONFIG")
  let prev_dc = @env.get_env_var("DOCKER_CONFIG")
  let prev_home = @env.get_env_var("HOME")
  defer {
    restore_env("DOCKER_AUTH_CONFIG", prev_auth)
    restore_env("DOCKER_CONFIG", prev_dc)
    restore_env("HOME", prev_home)
    (@fs.remove("\{home}/.docker/config.json") catch { _ => () }) |> ignore
    (@fs.remove("\{home}/.docker") catch { _ => () }) |> ignore
    (@fs.remove(home) catch { _ => () }) |> ignore
    (@fs.remove(docker_config_dir) catch { _ => () }) |> ignore
    (@fs.remove(dir) catch { _ => () }) |> ignore
  }
  @env.unset_env_var("DOCKER_AUTH_CONFIG")
  @env.set_env_var("DOCKER_CONFIG", docker_config_dir)
  @env.set_env_var("HOME", home)
  // DOCKER_CONFIG set but no config.json inside → anonymous, no
  // fallback to HOME's (valid) config.
  assert_true(load_config_json() is None)
  // DOCKER_AUTH_CONFIG wins over everything.
  @env.set_env_var(
    "DOCKER_AUTH_CONFIG",
    "{\"auths\":{\"ghcr.io\":{\"auth\":\"\{DUMMY_B64}\"}}}",
  )
  match load_config_json() {
    Some(j) => assert_true(j.contains("ghcr.io"))
    None => fail("expected inline config")
  }
  // Unset DOCKER_CONFIG → HOME is used.
  @env.unset_env_var("DOCKER_CONFIG")
  @env.unset_env_var("DOCKER_AUTH_CONFIG")
  match load_config_json() {
    Some(j) => assert_true(j.contains("ghcr.io"))
    None => fail("expected HOME config")
  }
}

///|
fn restore_env(name : String, prev : String?) -> Unit {
  match prev {
    Some(v) => @env.set_env_var(name, v)
    None => @env.unset_env_var(name)
  }
}

///|
async test "pull attaches X-Registry-Auth; failure leaks no credentials" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let captured : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  let prev = @env.get_env_var("DOCKER_AUTH_CONFIG")
  defer restore_env("DOCKER_AUTH_CONFIG", prev)
  let secret = "s3cr3t-token-value"
  @env.set_env_var(
    "DOCKER_AUTH_CONFIG",
    "{\"auths\":{\"https://index.docker.io/v1/\":{\"identitytoken\":\"\{secret}\"}}}",
  )
  // serve_mock_engine records only request first-lines; keep the full
  // wire request (headers included) via the respond closure.
  let wire : Array[String] = []
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        2,
        fn(request) {
          wire.push(request)
          // First pull streams a clean response; the second is a 401 —
          // its error must not echo the token.
          if wire.length() == 1 {
            http_200("{\"status\":\"ok\"}")
          } else {
            http_resp("401", "Unauthorized", "{\"message\":\"no\"}")
          }
        },
        captured,
      )
    })
    let client = DockerClient::new(socket_path=sock)
    client.pull_image("alpine:latest")
    try client.pull_image("alpine:latest") catch {
      err => {
        let msg = err.to_string()
        assert_true(!msg.contains(secret))
        assert_true(!msg.contains(b64(secret)))
      }
    } noraise {
      _ => fail("expected Unauthorized")
    }
  })
  // Verify the header actually went out on the wire.
  let mut saw_auth = false
  for req in wire {
    if req.contains("X-Registry-Auth: ") {
      saw_auth = true
      // The wire value is the one place the secret legitimately
      // appears: base64'd JSON containing the token.
      let head = req.find("X-Registry-Auth: ").unwrap() + 17
      let tail = req[head:].find("\r\n").unwrap() + head
      let encoded = req[head:tail].to_owned()
      let decoded = @utf8.decode(@base64.decode(encoded[:])[:])
      assert_true(decoded.contains(secret))
    }
  }
  assert_true(saw_auth)
}
