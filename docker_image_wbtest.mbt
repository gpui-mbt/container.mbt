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
test "percent_encode encodes slashes and leaves unreserved alone" {
  assert_eq(percent_encode("alpine"), "alpine")
  assert_eq(percent_encode("ghcr.io/org/app"), "ghcr.io%2Forg%2Fapp")
  assert_eq(percent_encode("img:1.0@sha256:ab"), "img%3A1.0%40sha256%3Aab")
  assert_eq(percent_encode("a b+c"), "a%20b%2Bc")
  assert_eq(percent_encode("._-~"), "._-~")
}

///|
test "split_pull_reference ports the upstream cases" {
  assert_eq(split_pull_reference("alpine:3.20"), ("alpine", "3.20"))
  assert_eq(split_pull_reference("alpine"), ("alpine", "latest"))
  assert_eq(
    split_pull_reference("localhost:5000/nginx:latest"),
    ("localhost:5000/nginx", "latest"),
  )
  assert_eq(
    split_pull_reference("registry:5000/org/app:1.2"),
    ("registry:5000/org/app", "1.2"),
  )
  assert_eq(split_pull_reference("img@sha256:abcdef"), ("img", "sha256:abcdef"))
  assert_eq(
    split_pull_reference("img:1.0@sha256:abcdef"),
    ("img", "sha256:abcdef"),
  )
  assert_eq(split_pull_reference("img:"), ("img", "latest"))
  assert_eq(split_pull_reference("img@"), ("img", "latest"))
}

///|
test "pull stream accepts progress, aux, and empty lines" {
  check_pull_stream_errors(
    @utf8.encode(
      "{\"status\":\"Pulling from library/alpine\"}\n{\"status\":\"Downloading\",\"progressDetail\":{}}\n\n{\"aux\":{\"ID\":\"sha256:1\"}}\n",
    ),
    op="pull image",
  )
}

///|
test "pull stream accepts an empty body and empty error fields" {
  check_pull_stream_errors(b"", op="pull image")
  check_pull_stream_errors(
    @utf8.encode("{\"error\":\"\",\"errorDetail\":{\"message\":\"\"}}"),
    op="pull image",
  )
}

///|
test "pull stream fails on non-empty error at any line position" {
  try
    check_pull_stream_errors(
      @utf8.encode(
        "{\"status\":\"Downloading\"}\n{\"error\":\"manifest unknown\"}\n",
      ),
      op="pull image",
    )
  catch {
    EngineError::PullFailed(op="pull image", message="manifest unknown") => ()
    err => fail("expected PullFailed, got \{err}")
  } noraise {
    _ => fail("expected PullFailed")
  }
}

///|
test "pull stream fails on errorDetail.message alone" {
  try
    check_pull_stream_errors(
      @utf8.encode("{\"errorDetail\":{\"message\":\"unauthorized\"}}"),
      op="pull image",
    )
  catch {
    EngineError::PullFailed(op="pull image", message="unauthorized") => ()
    err => fail("expected PullFailed, got \{err}")
  } noraise {
    _ => fail("expected PullFailed")
  }
}

///|
test "pull stream rejects non-object, bad JSON, and non-UTF-8 bodies" {
  try check_pull_stream_errors(@utf8.encode("[1,2]\n"), op="pull image") catch {
    EngineError::MalformedResponse(op="pull image", ..) => ()
    err => fail("expected MalformedResponse, got \{err}")
  } noraise {
    _ => fail("expected MalformedResponse")
  }
  try
    check_pull_stream_errors(@utf8.encode("{not json\n"), op="pull image")
  catch {
    EngineError::MalformedResponse(op="pull image", ..) => ()
    err => fail("expected MalformedResponse, got \{err}")
  } noraise {
    _ => fail("expected MalformedResponse")
  }
  try check_pull_stream_errors(b"\xff\xfe\n", op="pull image") catch {
    EngineError::MalformedResponse(op="pull image", ..) => ()
    err => fail("expected MalformedResponse, got \{err}")
  } noraise {
    _ => fail("expected MalformedResponse")
  }
}

///|
async test "resolve returns the descriptor on 200 and never pulls" {
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
        1,
        fn(_head) { http_200("{\"Id\":\"sha256:x\"}") },
        requests,
      )
    })
    let client = DockerClient::new(socket_path=sock)
    let d = client.resolve_or_pull_image("ghcr.io/org/app:1.0")
    assert_eq(d, "ghcr.io/org/app:1.0")
    // Path segment must be percent-encoded; no /images/create call.
    assert_eq(requests, ["GET /images/ghcr.io%2Forg%2Fapp%3A1.0/json HTTP/1.1"])
  })
}

///|
async test "resolve 404 pulls once then re-resolves" {
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
      let mut resolve_count = 0
      serve_mock_engine(
        listen_fd,
        3,
        fn(head) {
          if head.contains("GET /images/") {
            // First resolve 404s, the post-pull resolve succeeds.
            resolve_count = resolve_count + 1
            if resolve_count == 1 {
              http_resp("404", "Not Found", "{\"message\":\"No such image\"}")
            } else {
              http_200("{\"Id\":\"sha256:ok\"}")
            }
          } else {
            http_200("{\"status\":\"Pull complete\"}\n")
          }
        },
        requests,
      )
    })
    let client = DockerClient::new(socket_path=sock)
    let d = client.resolve_or_pull_image("alpine:3.20")
    assert_eq(d, "alpine:3.20")
    assert_eq(requests, [
      "GET /images/alpine%3A3.20/json HTTP/1.1", "POST /images/create?fromImage=alpine&tag=3.20 HTTP/1.1",
      "GET /images/alpine%3A3.20/json HTTP/1.1",
    ])
  })
}

///|
async test "a pull 401 is Unauthorized, not ImageNotFound" {
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
          if head.contains("GET /images/") {
            http_resp("404", "Not Found", "{\"message\":\"No such image\"}")
          } else {
            http_resp(
              "401", "Unauthorized", "{\"message\":\"unauthorized: authentication required\"}",
            )
          }
        },
        [],
      )
    })
    let client = DockerClient::new(socket_path=sock)
    try client.resolve_or_pull_image("private.example.com/team/app:2.0") catch {
      EngineError::Unauthorized(op="pull image", ..) => ()
      err => fail("expected Unauthorized, got \{err}")
    } noraise {
      _ => fail("expected Unauthorized")
    }
  })
}

///|
async test "a mid-stream pull error fails the pull" {
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
        1,
        fn(_head) {
          http_200(
            "{\"status\":\"Pulling\"}\n{\"errorDetail\":{\"message\":\"blob fetch failed\"}}\n",
          )
        },
        [],
      )
    })
    let client = DockerClient::new(socket_path=sock)
    try client.pull_image("alpine:3.20") catch {
      EngineError::PullFailed(op="pull image", message="blob fetch failed") =>
        ()
      err => fail("expected PullFailed, got \{err}")
    } noraise {
      _ => fail("expected PullFailed")
    }
  })
}

///|
async test "a stalled pull dies at the shared deadline" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  let deadline = Deadline::after(300)
  let start = @async.now()
  let mut elapsed : Int64 = -1L
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      // Accept and read the request, then stall like a hung registry.
      let mut fd : Int32? = None
      for spin = 0; spin < 10_000 && fd is None; spin = spin + 1 {
        fd = unix_accept(listen_fd)
        if fd is None {
          @async.sleep(1)
        }
      }
      let conn = unix_socket_from_fd(fd.unwrap())
      defer conn.close()
      ignore(conn.read_until("\r\n\r\n"))
      @async.sleep(800)
    })
    let client = DockerClient::new(socket_path=sock)
    try client.pull_image("alpine:3.20", deadline~) catch {
      EngineError::DeadlineExceeded(op="pull image") => {
        elapsed = @async.now() - start
        ()
      }
      err => fail("expected DeadlineExceeded, got \{err}")
    } noraise {
      _ => fail("expected DeadlineExceeded")
    }
  })
  assert_true(elapsed >= 300L && elapsed < 2000L)
}
