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
/// Accept `count` connections on `listen_fd`, answer each via `respond`
/// (full request head → response bytes), record request first-lines into
/// `requests`. Runs inside a task group (spawn_bg).
async fn serve_mock_engine(
  listen_fd : Int32,
  count : Int32,
  respond : (String) -> Bytes,
  requests : Array[String],
) -> Unit {
  for i = 0; i < count; i = i + 1 {
    let mut fd : Int32? = None
    for spin = 0; spin < 10_000 && fd is None; spin = spin + 1 {
      fd = unix_accept(listen_fd)
      if fd is None {
        @async.sleep(1)
      }
    }
    let conn = unix_socket_from_fd(fd.unwrap())
    defer conn.close()
    let head = conn.read_until("\r\n\r\n").unwrap_or("")
    requests.push(head.split("\r\n").collect()[0].to_owned())
    // Consume the request body too — leaving it unread makes close()
    // RST the in-flight response, and hides POST bodies from respond().
    let mut request = head
    for line in head.split("\r\n") {
      if ascii_lower(line.to_owned()).has_prefix("content-length:") {
        let mut n = 0
        for c in line[15:] {
          if c is ('0'..<='9') {
            n = n * 10 + (c.to_int() - '0'.to_int())
          }
        }
        if n > 0 {
          let body = conn.read_exactly(n)
          request = "\{head}\r\n\r\n\{@utf8.decode_lossy(body)}"
        }
      }
    }
    conn.write_all(respond(request))
  }
}

///|
fn http_200(body : String) -> Bytes {
  @utf8.encode(
    "HTTP/1.1 200 OK\r\nContent-Length: \{body.length()}\r\nConnection: close\r\n\r\n\{body}",
  )
}

///|
/// `HTTP/1.1 \{status} \{reason}` with a computed Content-Length.
fn http_resp(status : String, reason : String, body : String) -> Bytes {
  @utf8.encode(
    "HTTP/1.1 \{status} \{reason}\r\nContent-Length: \{body.length()}\r\nConnection: close\r\n\r\n\{body}",
  )
}

///|
async test "preflight succeeds against a mock engine" {
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
        2,
        fn(head) {
          if head.contains("GET /_ping ") {
            http_200("OK")
          } else if head.contains("GET /version ") {
            http_200("{\"ApiVersion\":\"1.44\",\"Version\":\"25.0.1\"}")
          } else {
            http_200("{}")
          }
        },
        requests,
      )
    })
    let client = DockerClient::new(socket_path=sock)
    let v = client.preflight()
    assert_eq(v.api_version, "1.44")
    assert_eq(v.version, "25.0.1")
    assert_eq(requests, ["GET /_ping HTTP/1.1", "GET /version HTTP/1.1"])
  })
}

///|
async test "stopped daemon classifies as transport error, not CLI failure" {
  let client = DockerClient::new(
    socket_path="/tmp/container-mbt-no-daemon.sock",
  )
  try client.preflight() catch {
    EngineError::TransportError(op="ping", ..) => ()
    err => fail("expected TransportError, got \{err}")
  } noraise {
    _ => fail("expected preflight to fail")
  }
}

///|
async test "a non-Docker service on the socket is diagnosed" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_mock_engine(listen_fd, 1, fn(_head) { b"HELLO not-http" }, [])
    })
    let client = DockerClient::new(socket_path=sock)
    try client.preflight() catch {
      EngineError::MalformedResponse(op="ping", ..)
      | EngineError::TransportError(op="ping", ..) => ()
      err => fail("expected MalformedResponse/TransportError, got \{err}")
    } noraise {
      _ => fail("expected preflight to fail")
    }
  })
}

///|
async test "an old API version fails before any side effects" {
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
          if head.contains("GET /version ") {
            http_200("{\"ApiVersion\":\"1.20\",\"Version\":\"1.0\"}")
          } else {
            http_200("OK")
          }
        },
        [],
      )
    })
    let client = DockerClient::new(socket_path=sock)
    try client.preflight() catch {
      EngineError::ApiVersionTooOld(
        op="preflight",
        found="1.20",
        required="1.24"
      ) => ()
      err => fail("expected ApiVersionTooOld, got \{err}")
    } noraise {
      _ => fail("expected preflight to fail")
    }
  })
}

///|
test "api version comparison is numeric" {
  assert_true(api_version_at_least("1.24", "1.24"))
  assert_true(api_version_at_least("1.44", "1.24"))
  assert_true(api_version_at_least("2.0", "1.99"))
  assert_true(!api_version_at_least("1.23", "1.24"))
  assert_true(!api_version_at_least("garbage", "1.24"))
}
