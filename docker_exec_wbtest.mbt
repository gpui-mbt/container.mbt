// Copyright 2026 gpui-mbt contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

///|
/// One multiplexed frame: type byte + 3 reserved + BE u32 length + payload.
fn exec_frame(stream_type : Int32, payload : Bytes) -> Bytes {
  let out : Array[Byte] = [stream_type.to_byte(), 0, 0, 0]
  let n = payload.length()
  out.push((n >> 24).to_byte())
  out.push((n >> 16).to_byte())
  out.push((n >> 8).to_byte())
  out.push(n.to_byte())
  for b in payload {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// Response with explicit headers and a binary body.
fn http_stream_resp(content_type : String, body : Bytes) -> Bytes {
  let head = @utf8.encode(
    "HTTP/1.1 200 OK\r\nContent-Type: \{content_type}\r\nContent-Length: \{body.length()}\r\nConnection: close\r\n\r\n",
  )
  let out : Array[Byte] = []
  for b in head {
    out.push(b)
  }
  for b in body {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
test "demux separates interleaved stdout and stderr frames" {
  let out = b"out-1"
  let err = b"err-1"
  let stream = exec_frame(1, out) + exec_frame(2, err) + exec_frame(1, b"out-2")
  let (stdout, stderr) = demux_exec_stream(stream)
  assert_eq(@utf8.decode_lossy(stdout), "out-1out-2")
  assert_eq(@utf8.decode_lossy(stderr), "err-1")
}

///|
test "demux drops stdin/unknown frames and keeps zero-length frames" {
  let stream = exec_frame(0, b"in") +
    exec_frame(9, b"???") +
    exec_frame(1, b"") +
    exec_frame(1, b"keep")
  let (stdout, stderr) = demux_exec_stream(stream)
  assert_eq(@utf8.decode_lossy(stdout), "keep")
  assert_eq(@utf8.decode_lossy(stderr), "")
}

///|
test "demux keeps a truncated trailing payload like upstream" {
  // Declares 10 bytes but only 4 arrive — partial payload is kept.
  let stream = exec_frame(1, b"ok") +
    Bytes::from_array([1, 0, 0, 0, 0, 0, 0, 10, b'p', b'a', b'r', b't'])
  let (stdout, stderr) = demux_exec_stream(stream)
  assert_eq(@utf8.decode_lossy(stdout), "okpart")
  assert_eq(@utf8.decode_lossy(stderr), "")
}

///|
test "exec inspect parses Running and ExitCode" {
  assert_eq(
    parse_exec_inspect_state(
      @utf8.encode("{\"Running\":true,\"ExitCode\":null}"),
      op="exec",
    ),
    (true, None),
  )
  assert_eq(
    parse_exec_inspect_state(
      @utf8.encode("{\"Running\":false,\"ExitCode\":7}"),
      op="exec",
    ),
    (false, Some(7)),
  )
  // Missing Running is treated as finished (upstream tolerance).
  assert_eq(
    parse_exec_inspect_state(@utf8.encode("{\"ExitCode\":3}"), op="exec"),
    (false, Some(3)),
  )
  try parse_exec_inspect_state(@utf8.encode("not json"), op="exec") catch {
    EngineError::MalformedResponse(op="exec", ..) => ()
    err => fail("expected MalformedResponse, got \{err}")
  } noraise {
    _ => fail("expected MalformedResponse")
  }
}

///|
test "exec env overrides container env by key" {
  let merged = merge_exec_env(["A=1", "B=keep", "C=3"], [
    ("A", "2"),
    ("D", "new"),
  ])
  assert_eq(merged, ["B=keep", "C=3", "A=2", "D=new"])
}

///|
async test "exec runs create, start, inspect and demuxes output" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
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
        3,
        fn(head) {
          if head.contains("/exec/") && head.contains("/start") {
            http_stream_resp(
              "application/vnd.docker.multiplexed-stream",
              exec_frame(1, b"out") + exec_frame(2, b"err"),
            )
          } else if head.contains("GET /exec/") {
            http_200("{\"Running\":false,\"ExitCode\":7}")
          } else {
            http_200("{\"Id\":\"exec42\"}")
          }
        },
        requests,
      )
    })
    let client = DockerClient::new(socket_path=sock)
    let r = client.exec("abc", cmd=["sh", "-c", "x"])
    assert_eq(r.exit_code, 7)
    assert_eq(@utf8.decode_lossy(r.stdout), "out")
    assert_eq(@utf8.decode_lossy(r.stderr), "err")
    assert_eq(requests, [
      "POST /containers/abc/exec HTTP/1.1", "POST /exec/exec42/start HTTP/1.1", "GET /exec/exec42/json HTTP/1.1",
    ])
  })
}

///|
async test "exec env triggers inspect plus merged Env in create" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let bodies : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      let mut call = 0
      serve_mock_engine(
        listen_fd,
        4,
        fn(head) {
          call = call + 1
          match call {
            1 =>
              http_200(
                "{\"State\":{\"Running\":true},\"Config\":{\"Env\":[\"A=1\",\"B=keep\"]}}",
              )
            2 => {
              // Record the exec create body (after the head terminator).
              let idx = head.split("\r\n\r\n").collect()
              if idx.length() > 1 {
                bodies.push(idx[1].to_owned())
              }
              http_200("{\"Id\":\"e1\"}")
            }
            3 =>
              http_stream_resp("application/vnd.docker.multiplexed-stream", b"")
            _ => http_200("{\"Running\":false,\"ExitCode\":0}")
          }
        },
        [],
      )
    })
    let client = DockerClient::new(socket_path=sock)
    let r = client.exec("abc", cmd=["env"], env=[("A", "2")])
    assert_eq(r.exit_code, 0)
    assert_eq(bodies.length(), 1)
    assert_true(bodies[0].contains("\"Env\":[\"B=keep\",\"A=2\"]"))
  })
}

///|
async test "exec retries inspect until Running settles" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    let mut inspect_count = 0
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        5,
        fn(head) {
          if head.contains("/start") {
            http_stream_resp("application/vnd.docker.multiplexed-stream", b"")
          } else if head.contains("GET /exec/") {
            inspect_count = inspect_count + 1
            if inspect_count < 3 {
              http_200("{\"Running\":true,\"ExitCode\":null}")
            } else {
              http_200("{\"Running\":false,\"ExitCode\":2}")
            }
          } else {
            http_200("{\"Id\":\"e9\"}")
          }
        },
        [],
      )
    })
    let client = DockerClient::new(socket_path=sock)
    let r = client.exec("abc", cmd=["true"])
    assert_eq(r.exit_code, 2)
    assert_eq(inspect_count, 3)
  })
}

///|
async test "an unsettled exec exit code is an explicit error, not 0" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
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
        8, // create + start + 6 inspect attempts
        fn(head) {
          if head.contains("/start") {
            http_stream_resp("application/vnd.docker.multiplexed-stream", b"")
          } else if head.contains("GET /exec/") {
            http_200("{\"Running\":true,\"ExitCode\":null}")
          } else {
            http_200("{\"Id\":\"stuck\"}")
          }
        },
        [],
      )
    })
    let client = DockerClient::new(socket_path=sock)
    try client.exec("abc", cmd=["true"]) catch {
      EngineError::ExecExitUndetermined(op="exec", exec_id="stuck") => ()
      err => fail("expected ExecExitUndetermined, got \{err}")
    } noraise {
      _ => fail("expected ExecExitUndetermined")
    }
  })
}

///|
async test "a raw-stream exec response is rejected, not frame-decoded" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
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
        2,
        fn(head) {
          if head.contains("/start") {
            http_stream_resp(
              "application/vnd.docker.raw-stream", b"raw tty bytes",
            )
          } else {
            http_200("{\"Id\":\"tty\"}")
          }
        },
        [],
      )
    })
    let client = DockerClient::new(socket_path=sock)
    try client.exec("abc", cmd=["sh"]) catch {
      EngineError::MalformedResponse(op="exec", ..) => ()
      err => fail("expected MalformedResponse, got \{err}")
    } noraise {
      _ => fail("expected MalformedResponse")
    }
  })
}
