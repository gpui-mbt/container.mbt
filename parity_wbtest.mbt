///|
/// Issue 0048 — ContainerRequest-style overrides and the start-time
/// snapshot boundary.

///|
test "with_name/with_tag override the descriptor" {
  let image = GenericImage::new("alpine", "3.20")
  assert_eq(image.descriptor(), "alpine:3.20")
  let overridden = image.with_name("debian").with_tag("12")
  assert_eq(overridden.descriptor(), "debian:12")
  // Empty values are rejected like the constructor.
  assert_true(
    try {
      ignore(GenericImage::new("a", "1").with_name(""))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(GenericImage::new("a", "1").with_tag(""))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "with_labels merges per-key last-wins" {
  let image = GenericImage::new("a", "1")
    .with_label("k", "v1")
    .with_label("other", "x")
    .with_labels([("k", "v2"), ("third", "y")])
  let args = build_run_args(
    Docker,
    image,
    attempt=fixture_attempt("labels", "fixture-run-id"),
  ).join(" ")
  // k=v2 appears exactly once; v1 is gone.
  assert_true(args.contains("k=v2"))
  assert_true(!args.contains("k=v1"))
  assert_true(args.contains("other=x"))
  assert_true(args.contains("third=y"))
}

///|
test "env override emits a single key" {
  let image = GenericImage::new("a", "1")
    .with_env_var("A", "one")
    .with_env_var("A", "two")
  let args = build_run_args(
    Docker,
    image,
    attempt=fixture_attempt("env", "fixture-run-id"),
  ).join(" ")
  let joined = "--env \{args}" // marker so exact-count is checkable
  let mut count = 0
  for part in joined.split(" ") {
    if part.to_owned() == "A=two" {
      count = count + 1
    }
    if part.to_owned() == "A=one" {
      fail("stale env value must not be emitted")
    }
  }
  assert_eq(count, 1)
}

///|
test "with_ready_conditions replaces; with_wait_for accumulates" {
  let image = GenericImage::new("a", "1")
    .with_wait_for(WaitFor::message_on_stdout("first"))
    .with_wait_for(WaitFor::message_on_stdout("second"))
  assert_eq(image.ready_conditions.length(), 2)
  let replaced = image.with_ready_conditions([WaitFor::millis(10)])
  assert_eq(replaced.ready_conditions.length(), 1)
  // Replacing copies the input — mutating the source array after the
  // call must not leak into the image.
  let src : Array[WaitFor] = [WaitFor::millis(5)]
  let img2 = GenericImage::new("a", "1").with_ready_conditions(src)
  src.push(WaitFor::millis(6))
  assert_eq(img2.ready_conditions.length(), 1)
}

///|
async test "start_with_client does not mutate the caller's builder" {
  let dir = @fs.tmpdir(prefix="container-mbt-parity")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  let resolves : Ref[Int32] = { val: 0, }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        5, // resolve(404) → pull → resolve(200) → create → start
        fn(head) {
          if head.contains("GET /images/") {
            resolves.val = resolves.val + 1
            if resolves.val == 1 {
              http_resp("404", "Not Found", "{\"message\":\"missing\"}")
            } else {
              http_200("{\"Id\":\"img\"}")
            }
          } else if head.contains("POST /images/create") {
            http_200("{\"status\":\"ok\"}")
          } else if head.contains("POST /containers/create") {
            http_200("{\"Id\":\"abc123\"}")
          } else if head.contains("/start") {
            http_resp("204", "No Content", "")
          } else {
            http_200("{}")
          }
        },
        [],
      )
    })
    let image = GenericImage::new("alpine", "3.20")
    let container = image.start_with_client(DockerClient::new(socket_path=sock))
    assert_true(image.container_name is None)
    assert_true(image.labels.is_empty())
    // The container itself is usable and the builder can keep evolving.
    ignore(image.with_env_var("POST", "start"))
    ignore(container)
  })
}
