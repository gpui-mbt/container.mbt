///|
/// 0038: `when_exited` accepts any code; `exit_code` carries the
/// expectation into the Exit payload.
test "exit wait construction" {
  guard WaitFor::when_exited() is Exit(None) else { fail("when_exited") }
  guard WaitFor::exit_code(3) is Exit(Some(3)) else { fail("exit_code") }
}

///|
/// Build a `Container` whose ops route through the mock engine socket.
fn exit_fixture_container(sock : String) -> Container {
  {
    id: "ex1",
    runtime: Docker,
    mappings: [],
    removed: false,
    resolved_ports: None,
    inspect_obj: None,
    client: Some(DockerClient::new(socket_path=sock)),
  }
}

///|
/// Scripted inspect body with an exit code.
fn exit_inspect_body(running : Bool, code : Int32?) -> String {
  let mut b = "{\"State\":{\"Running\":\{running}"
  match code {
    Some(c) => b = "\{b},\"ExitCode\":\{c}"
    None => ()
  }
  "\{b}}}"
}

///|
/// 0038: running → stopped poll sequence; `when_exited` completes
/// without checking a code.
async test "exit wait completes on stop" {
  let dir = @fs.tmpdir(prefix="container-mbt-ex")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let requests : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      let bodies = [
        exit_inspect_body(true, None),
        exit_inspect_body(false, Some(0)),
      ]
      let mut i = 0
      serve_mock_engine(
        listen_fd,
        2,
        fn(_head) {
          let b = bodies[i]
          i = i + 1
          http_200(b)
        },
        requests,
      )
    })
    exit_fixture_container(sock).exit_wait_until(None, @async.now() + 20000)
    assert_eq(requests.length(), 2)
  })
}

///|
/// 0038: expected code matches → success; mismatched and missing
/// codes fail with expected/actual detail.
async test "exit wait verifies expected code" {
  let dir = @fs.tmpdir(prefix="container-mbt-ex2")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let requests : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      // match(3→3), mismatch(3 vs 0), missing code
      let bodies = [
        exit_inspect_body(false, Some(3)),
        exit_inspect_body(false, Some(0)),
        exit_inspect_body(false, None),
      ]
      let mut i = 0
      serve_mock_engine(
        listen_fd,
        3,
        fn(_head) {
          let b = bodies[i]
          i = i + 1
          http_200(b)
        },
        requests,
      )
    })
    let c = exit_fixture_container(sock)
    c.exit_wait_until(Some(3), @async.now() + 20000)
    let r1 = try {
      c.exit_wait_until(Some(3), @async.now() + 20000)
      "waited"
    } catch {
      e =>
        if "\{e}".contains("expected 3, got 0") {
          "mismatch"
        } else {
          "other:\{e}"
        }
    }
    assert_eq(r1, "mismatch")
    let r2 = try {
      c.exit_wait_until(Some(0), @async.now() + 20000)
      "waited"
    } catch {
      e =>
        if "\{e}".contains("did not report an exit code") {
          "no-code"
        } else {
          "other:\{e}"
        }
    }
    assert_eq(r2, "no-code")
    assert_eq(requests.length(), 3)
  })
}

///|
/// 0038: a container without a direct client reports the CLI-adapter
/// refusal instead of polling.
async test "cli container rejects exit wait" {
  let bare : Container = {
    id: "t",
    runtime: Docker,
    mappings: [],
    removed: false,
    resolved_ports: None,
    inspect_obj: None,
    client: None,
  }
  let r = try {
    bare.exit_wait_until(None, @async.now() + 5000)
    "waited"
  } catch {
    e =>
      if "\{e}".contains("CLI adapters") {
        "cli-refusal"
      } else {
        "other:\{e}"
      }
  }
  assert_eq(r, "cli-refusal")
}

///|
/// 0038: `cmd_wait_check` — stdout condition never matches stderr and
/// vice versa; exit code comparison is exact.
test "cmd wait matching is stream-exact" {
  let out : ProcessOutput = {
    exit_code: 0,
    stdout: "ready now",
    stderr: "warn",
  }
  assert_true(cmd_wait_check(CmdWaitFor::nothing(), out) is None)
  assert_true(cmd_wait_check(CmdWaitFor::stdout_message("ready"), out) is None)
  // A stderr-only message must not satisfy a stdout condition.
  assert_true(
    cmd_wait_check(CmdWaitFor::stdout_message("warn"), out) is Some(_),
  )
  assert_true(cmd_wait_check(CmdWaitFor::stderr_message("warn"), out) is None)
  assert_true(
    cmd_wait_check(CmdWaitFor::stderr_message("ready"), out) is Some(_),
  )
  assert_true(cmd_wait_check(CmdWaitFor::exit(None), out) is None)
  assert_true(cmd_wait_check(CmdWaitFor::exit(Some(0)), out) is None)
  let mismatch = cmd_wait_check(CmdWaitFor::exit(Some(1)), out)
  assert_true(mismatch is Some(_))
  assert_true(mismatch.unwrap().contains("expected 1, got 0"))
}

///|
/// 0038: `exec_wait` applies the message condition to the captured
/// buffer — end-to-end over the mock engine exec path.
async test "exec_wait matches buffered output" {
  let dir = @fs.tmpdir(prefix="container-mbt-xw")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let requests : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      let mut i = 0
      serve_mock_engine(
        listen_fd,
        6,
        fn(_head) {
          i = i + 1
          match i {
            // exec create → id
            1 => http_200("{\"Id\":\"exec-a\"}")
            // exec start → multiplexed frame: stream=1, payload "hello"
            2 =>
              http_stream_resp(
                "application/vnd.docker.multiplexed-stream",
                exec_frame(1, @utf8.encode("hello")),
              )
            // exec inspect → settled, code 0
            3 => http_200("{\"Running\":false,\"ExitCode\":0}")
            // second exec cycle
            4 => http_200("{\"Id\":\"exec-b\"}")
            5 =>
              http_stream_resp(
                "application/vnd.docker.multiplexed-stream",
                exec_frame(2, @utf8.encode("oops")),
              )
            _ => http_200("{\"Running\":false,\"ExitCode\":7}")
          }
        },
        requests,
      )
    })
    let c = exit_fixture_container(sock)
    // stdout message matches buffered stdout.
    let out = c.exec_wait(
      ["echo", "hello"],
      wait=CmdWaitFor::stdout_message("hello"),
    )
    assert_eq(out.exit_code(), 0)
    // stderr message + exit code 7 → mismatch with expected 0.
    let r = try {
      ignore(c.exec_wait(["false"], wait=CmdWaitFor::stderr_message("nope")))
      "ok"
    } catch {
      e =>
        if "\{e}".contains("not found on stderr") {
          "msg-mismatch"
        } else {
          "other:\{e}"
        }
    }
    assert_eq(r, "msg-mismatch")
  })
}
