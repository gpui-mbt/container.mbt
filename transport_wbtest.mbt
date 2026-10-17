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
test "default docker socket path matches upstream" {
  assert_eq(DEFAULT_DOCKER_SOCKET_PATH, "/var/run/docker.sock")
  let transport = UnixSocketTransport::new()
  assert_eq(transport.socket_path, "/var/run/docker.sock")
  assert_eq(transport.connect_timeout_ms, 30_000)
}

///|
/// Connect to `path` and return the error, or fail the test.
async fn connect_error(path : String) -> Error {
  try UnixSocketTransport::new(socket_path=path).connect() catch {
    err => err
  } noraise {
    _ => fail("expected connect to fail for \{path}")
  }
}

///|
async test "connect classifies a missing socket path" {
  let err = connect_error("/tmp/container-mbt-definitely-missing.sock")
  guard err is SocketConnectError::SocketMissing(_) else {
    fail("expected SocketMissing, got \{err}")
  }
}

///|
async test "connect classifies a non-socket path as refused" {
  let dir = @fs.tmpdir(prefix="container-mbt-transport")
  let path = "\{dir}/not-a-socket"
  @fs.write_file(path, "plain file")
  let err = connect_error(path)
  guard err is SocketConnectError::Refused(_) else {
    fail("expected Refused, got \{err}")
  }
}

///|
async test "connect classifies permission failures" {
  let dir = @fs.tmpdir(prefix="container-mbt-transport")
  @fs.chmod(dir, 0o000)
  defer (@fs.chmod(dir, 0o700) catch { _ => () })
  let err = connect_error("\{dir}/engine.sock")
  guard err is SocketConnectError::PermissionDenied(_) else {
    fail("expected PermissionDenied, got \{err}")
  }
}

///|
async test "connect rejects paths that cannot reach the kernel" {
  let invalid = connect_error("")
  guard invalid is SocketConnectError::ConnectFailed(22, _) else {
    fail("expected ConnectFailed(EINVAL), got \{invalid}")
  }
  let nul = connect_error("/tmp/a\u{0}b.sock")
  guard nul is SocketConnectError::ConnectFailed(36, _) else {
    fail("expected ConnectFailed(ENAMETOOLONG), got \{nul}")
  }
}

///|
async test "socketpair exchanges bytes in both directions" {
  let (a, b) = unix_socketpair()
  let sa = unix_socket_from_fd(a)
  let sb = unix_socket_from_fd(b)
  defer sa.close()
  defer sb.close()
  sa.write_all(b"ping")
  sb.write_all(b"pong")
  assert_eq(@utf8.decode_lossy(sa.read_exactly(4)), "pong")
  assert_eq(@utf8.decode_lossy(sb.read_exactly(4)), "ping")
}

///|
/// 0006 core acceptance: a real listen/accept unix socket round-trips a
/// `GET /_ping` request without the docker CLI.
async test "exchange over a real unix socket round-trips a request" {
  let dir = @fs.tmpdir(prefix="container-mbt-transport")
  let sock = "\{dir}/engine.sock"
  let listen_fd = unix_listen(sock)
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      let mut conn_fd : Int32? = None
      for i = 0; i < 10_000; i = i + 1 {
        conn_fd = unix_accept(listen_fd)
        if conn_fd is Some(_) {
          break
        }
        @async.sleep(1)
      }
      let server = unix_socket_from_fd(conn_fd.unwrap())
      defer server.close()
      // Consume the full request first: closing with unread data in the
      // receive queue would reset the connection and lose the response.
      guard (server.read_until("\r\n\r\n") catch { _ => None }) is Some(request) else {
        fail("server could not read request headers")
      }
      assert_true(request.has_prefix("GET /_ping "))
      server.write_all(
        b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK",
      )
    })
    let transport = UnixSocketTransport::new(socket_path=sock)
    let response = transport.exchange(
      b"GET /_ping HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n",
    )
    let text = @utf8.decode_lossy(response)
    assert_true(text.contains("200 OK"))
    assert_true(text.has_suffix("OK"))
  })
}

///|
/// A cancelled in-flight read must release the connection cleanly:
/// the fd stays closable afterwards instead of hanging.
async test "cancelled reads leave the connection closable" {
  let (a, b) = unix_socketpair()
  let sa = unix_socket_from_fd(a)
  let sb = unix_socket_from_fd(b)
  let outcome = @async.with_timeout_opt(50, () => sa.read_exactly(4))
  assert_true(outcome is None)
  sa.close()
  sb.close()
}

///|
/// Writing to a peer that already closed must raise promptly
/// (EPIPE/ECONNRESET) instead of blocking forever.
async test "writes to a closed peer raise instead of blocking" {
  let (a, b) = unix_socketpair()
  let sa = unix_socket_from_fd(a)
  unix_close_fd(b)
  let mut raised = false
  for i = 0; i < 64 && !raised; i = i + 1 {
    sa.write_all(Bytes::make(8192, 0)) catch {
      _ => raised = true
    }
    if !raised {
      @async.sleep(1)
    }
  }
  sa.close()
  assert_true(raised)
}

///|
/// Failed connects must close their fd every time; leaking fds would
/// surface as EMFILE long before 512 iterations.
async test "failed connects do not leak fds" {
  for i = 0; i < 512; i = i + 1 {
    let err = connect_error("/tmp/container-mbt-definitely-missing.sock")
    guard err is SocketConnectError::SocketMissing(_) else {
      fail("iteration \{i}: expected SocketMissing, got \{err}")
    }
  }
}
