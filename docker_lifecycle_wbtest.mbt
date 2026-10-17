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
async test "inspect parses State.Running and State.ExitCode" {
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
        fn(_head) { http_200("{\"State\":{\"Running\":true,\"ExitCode\":0}}") },
        [],
      )
    })
    let client = DockerClient::new(socket_path=sock)
    let s = client.inspect_container("abc")
    assert_true(s.running)
    assert_eq(s.exit_code, Some(0))
  })
}

///|
async test "inspect 404 is ContainerNotFound, not another container" {
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
          http_resp("404", "Not Found", "{\"message\":\"No such container\"}")
        },
        [],
      )
    })
    let client = DockerClient::new(socket_path=sock)
    try client.inspect_container("gone") catch {
      EngineError::ContainerNotFound(op="inspect container", container="gone") =>
        ()
      err => fail("expected ContainerNotFound, got \{err}")
    } noraise {
      _ => fail("expected ContainerNotFound")
    }
  })
}

///|
async test "stop normalizes t and tolerates 304 and 404" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let requests : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    let mut call = 0
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        4,
        fn(_head) {
          call = call + 1
          match call {
            1 => http_resp("304", "Not Modified", "") // already stopped
            2 => http_resp("404", "Not Found", "{\"message\":\"gone\"}")
            _ => http_resp("204", "No Content", "")
          }
        },
        requests,
      )
    })
    let client = DockerClient::new(socket_path=sock)
    client.stop_container("abc") // default → t=30, 304 tolerated
    client.stop_container("abc", timeout_seconds=-5) // negative → t=30, 404 tolerated
    client.stop_container("abc", timeout_seconds=0) // t=0 sent as-is
    client.stop_container("abc", timeout_seconds=7)
    assert_eq(requests, [
      "POST /containers/abc/stop?t=30 HTTP/1.1", "POST /containers/abc/stop?t=30 HTTP/1.1",
      "POST /containers/abc/stop?t=0 HTTP/1.1", "POST /containers/abc/stop?t=7 HTTP/1.1",
    ])
  })
}

///|
async test "remove is idempotent on 404 and keeps force" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let requests : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    let mut call = 0
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        2,
        fn(_head) {
          call = call + 1
          if call == 1 {
            http_resp("204", "No Content", "")
          } else {
            http_resp("404", "Not Found", "{\"message\":\"gone\"}")
          }
        },
        requests,
      )
    })
    let client = DockerClient::new(socket_path=sock)
    client.remove_container("abc", force=true)
    client.remove_container("abc", force=true) // second delete succeeds
    assert_eq(requests, [
      "DELETE /containers/abc?force=true HTTP/1.1", "DELETE /containers/abc?force=true HTTP/1.1",
    ])
  })
}

///|
async test "wait returns StatusCode and errors on a deleted container" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let requests : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    let mut call = 0
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        2,
        fn(_head) {
          call = call + 1
          if call == 1 {
            http_200("{\"StatusCode\":7}")
          } else {
            http_resp("404", "Not Found", "{\"message\":\"gone\"}")
          }
        },
        requests,
      )
    })
    let client = DockerClient::new(socket_path=sock)
    assert_eq(client.wait_container("abc"), 7)
    try client.wait_container("abc") catch {
      EngineError::ContainerNotFound(op="wait container", ..) => ()
      err => fail("expected ContainerNotFound, got \{err}")
    } noraise {
      _ => fail("expected ContainerNotFound")
    }
    assert_eq(requests, [
      "POST /containers/abc/wait?condition=not-running HTTP/1.1", "POST /containers/abc/wait?condition=not-running HTTP/1.1",
    ])
  })
}
