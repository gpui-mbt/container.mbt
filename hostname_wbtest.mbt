///|
/// Issue 0045 — with_hostname / with_host / HostGateway / network
/// existence preflight.

///|
test "hostname and extra hosts reach docker run argv" {
  let image = GenericImage::new("alpine", "latest")
    .with_hostname("myhost")
    .with_host_addr("db", "10.0.0.5")
    .with_host_gateway("hostgw")
  let args = build_run_args(
    Docker,
    image,
    attempt=fixture_attempt("net-container", "fixture-run-id"),
  ).join(" ")
  assert_true(args.contains("--hostname myhost"))
  assert_true(args.contains("--add-host db:10.0.0.5"))
  assert_true(args.contains("--add-host hostgw:host-gateway"))
}

///|
test "default image emits no hostname/add-host (backward compat)" {
  let args = build_run_args(
    Docker,
    GenericImage::new("alpine", "latest"),
    attempt=fixture_attempt("plain", "fixture-run-id"),
  ).join(" ")
  assert_true(!args.contains("--hostname"))
  assert_true(!args.contains("--add-host"))
}

///|
fn image_raises(f : () -> GenericImage raise) -> Bool {
  try {
    ignore(f())
    false
  } catch {
    _ => true
  }
}

///|
test "hostname and extra-host validation" {
  // Hostname: empty / whitespace rejected.
  assert_true(image_raises(() => GenericImage::new("a", "1").with_hostname("")))
  assert_true(
    image_raises(() => GenericImage::new("a", "1").with_hostname("bad host")),
  )
  assert_true(
    image_raises(() => GenericImage::new("a", "1").with_hostname("bad\nhost")),
  )
  // Extra-host key: empty / whitespace / colon rejected.
  assert_true(
    image_raises(() => GenericImage::new("a", "1").with_host_addr("", "1.2.3.4")),
  )
  assert_true(
    image_raises(() => {
      GenericImage::new("a", "1").with_host_addr("bad key", "1.2.3.4")
    }),
  )
  assert_true(
    image_raises(() => {
      GenericImage::new("a", "1").with_host_addr("bad:key", "1.2.3.4")
    }),
  )
  // Addr value: empty / whitespace rejected; IPv6 colons allowed.
  assert_true(
    image_raises(() => GenericImage::new("a", "1").with_host_addr("x", "")),
  )
  assert_true(
    image_raises(() => GenericImage::new("a", "1").with_host_addr("x", "1 .2")),
  )
  ignore(GenericImage::new("a", "1").with_host_addr("v6", "::1"))
}

///|
test "hostname/extra-hosts reach the Engine create JSON" {
  let image = GenericImage::new("alpine", "latest")
    .with_hostname("myhost")
    .with_host_addr("db", "10.0.0.5")
    .with_host_gateway("gw")
  let body = create_request(image).to_json()
  assert_true(body.contains("\"Hostname\":\"myhost\""))
  assert_true(
    body.contains("\"ExtraHosts\":[\"db:10.0.0.5\",\"gw:host-gateway\"]"),
  )
}

///|
test "hostname/extra-host capability verdicts" {
  assert_true(capability(DirectDocker, Hostname) is Supported)
  assert_true(capability(CliDocker, Hostname) is Supported)
  assert_true(capability(CliApple, Hostname) is Rejected(_))
  assert_true(capability(CliApple, ExtraHosts) is Rejected(_))
  // No hostname configured → setting is not in use → Apple unaffected.
  assert_true(
    !settings_in_use(GenericImage::new("a", "1"))
    .iter()
    .any(fn(s) { s is Hostname }),
  )
}

///|
test "network name rejects whitespace before side effects" {
  let bad = GenericImage::new("a", "1").with_network("bad net")
  let r = try {
    ignore(build_run_args(Docker, bad, attempt=fixture_attempt("n", "r")))
    false
  } catch {
    _ => true
  }
  assert_true(r)
}

///|
test "build_network_inspect_args" {
  assert_eq(
    build_network_inspect_args(Docker, "mynet").join(" "),
    "network inspect mynet",
  )
  assert_eq(
    build_network_inspect_args(AppleContainer, "mynet").join(" "),
    "network inspect mynet",
  )
}

///|
async test "network_exists distinguishes 200 and 404" {
  let dir = @fs.tmpdir(prefix="container-mbt-net")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let requests : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        2,
        fn(head) {
          if head.contains("GET /networks/existing ") {
            http_200("{\"Name\":\"existing\"}")
          } else {
            http_resp("404", "Not Found", "{\"message\":\"no such network\"}")
          }
        },
        requests,
      )
    })
    let client = DockerClient::new(socket_path=sock)
    assert_true(client.network_exists("existing"))
    assert_true(!client.network_exists("missing"))
    assert_eq(requests, [
      "GET /networks/existing HTTP/1.1", "GET /networks/missing HTTP/1.1",
    ])
  })
}

///|
async test "ensure_network_exists fails before create on absent network" {
  let dir = @fs.tmpdir(prefix="container-mbt-net404")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        1,
        fn(_head) {
          http_resp("404", "Not Found", "{\"message\":\"no such network\"}")
        },
        [],
      )
    })
    let image = GenericImage::new("a", "1").with_network("ghost")
    let client = DockerClient::new(socket_path=sock)
    let message = try {
      ensure_network_exists(image, Some(client), None)
      ""
    } catch {
      Failure::Failure(msg) => msg
      _ => "non-failure error"
    }
    assert_true(message.contains("network does not exist: ghost"))
  })
}
