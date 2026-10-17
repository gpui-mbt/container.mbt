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

// M1 transport: talk to the Docker Engine over its Unix-domain socket
// without spawning the `docker` CLI (issue 0006). The socket fd is
// created by `unix_transport.c` (socket/connect are POSIX-only) and the
// actual IO runs through `@raw_fd.RawFdStream` on the async event loop.

///|
/// Default socket path of a local Docker Engine daemon.
pub const DEFAULT_DOCKER_SOCKET_PATH : String = "/var/run/docker.sock"

///|
/// Linux errno values used to classify connect failures.
const ERRNO_EPERM : Int32 = 1

///|
const ERRNO_ENOENT : Int32 = 2

///|
const ERRNO_EACCES : Int32 = 13

///|
const ERRNO_EAGAIN : Int32 = 11

///|
const ERRNO_ENOTDIR : Int32 = 20

///|
const ERRNO_EINVAL : Int32 = 22

///|
const ERRNO_ENAMETOOLONG : Int32 = 36

///|
const ERRNO_ETIMEDOUT : Int32 = 110

///|
const ERRNO_ECONNREFUSED : Int32 = 111

///|
/// Why a Unix-socket connection could not be established. The error
/// names the socket path and carries the raw errno for `ConnectFailed`.
pub(all) suberror SocketConnectError {
  /// The socket path (or a parent directory) does not exist.
  SocketMissing(String)
  /// The socket path cannot be reached/opened due to permissions.
  PermissionDenied(String)
  /// Something other than a listening socket sits at the path.
  Refused(String)
  /// The connect did not complete within `connect_timeout_ms`.
  Timeout(String)
  /// Any other failure; payload is (errno, socket_path).
  ConnectFailed(Int32, String)
}

///|
/// Exposes `Show`'s methods as regular methods (compiler-recommended form).
pub extend SocketConnectError with Show::{to_string, output}

///|
pub impl Show for SocketConnectError with fn output(self, logger) {
  let text = match self {
    SocketMissing(path) =>
      "socket path \{path} does not exist (is the daemon running?)"
    PermissionDenied(path) => "permission denied opening \{path}"
    Refused(path) => "connection refused by \{path} (not a listening socket?)"
    Timeout(path) => "timed out connecting to \{path}"
    ConnectFailed(errno, path) =>
      "connect to \{path} failed with errno \{errno}"
  }
  logger.write_string(text)
}

///|
#borrow(path)
extern "C" fn ffi_unix_connect(path : Bytes, timeout_ms : Int32) -> Int32 = "moonbit_container_unix_connect"

///|
#borrow(path)
extern "C" fn ffi_unix_listen(path : Bytes, backlog : Int32) -> Int32 = "moonbit_container_unix_listen"

///|
extern "C" fn ffi_unix_accept(listen_fd : Int32) -> Int32 = "moonbit_container_unix_accept"

///|
extern "C" fn ffi_unix_socketpair() -> Int64 = "moonbit_container_unix_socketpair"

///|
extern "C" fn ffi_unix_close(fd : Int32) -> Int32 = "moonbit_container_unix_close"

///|
fn connect_error_of(errno : Int32, path : String) -> SocketConnectError {
  match errno {
    ERRNO_EPERM | ERRNO_EACCES => PermissionDenied(path)
    ERRNO_ENOENT | ERRNO_ENOTDIR => SocketMissing(path)
    ERRNO_ECONNREFUSED => Refused(path)
    ERRNO_ETIMEDOUT => Timeout(path)
    n => ConnectFailed(n, path)
  }
}

///|
fn check_path(path : String) -> Bytes raise SocketConnectError {
  if path.is_empty() {
    raise SocketConnectError::ConnectFailed(ERRNO_EINVAL, path)
  }
  if path.contains_char('\u{0}') {
    raise SocketConnectError::ConnectFailed(ERRNO_ENAMETOOLONG, path)
  }
  @utf8.encode(path)
}

///|
/// How to reach a Unix-domain socket service, e.g. the Docker Engine
/// API at `/var/run/docker.sock`.
pub struct UnixSocketTransport {
  socket_path : String
  connect_timeout_ms : Int32
}

///|
pub fn UnixSocketTransport::new(
  socket_path~ : String = DEFAULT_DOCKER_SOCKET_PATH,
  connect_timeout_ms~ : Int32 = 30_000,
) -> UnixSocketTransport {
  { socket_path, connect_timeout_ms, }
}

///|
/// An established async connection over a Unix-domain socket.
pub struct UnixSocket {
  stream : @raw_fd.RawFdStream
}

///|
/// Connect to `self.socket_path` without invoking the `docker` CLI.
/// Failures are classified into `SocketConnectError` so callers can
/// distinguish "daemon not running" (SocketMissing/Refused) from
/// "permission problem" (PermissionDenied). The fd is closed on every
/// failure path; on success it is owned by the returned `UnixSocket`.
/// Note: the connect handshake itself runs a bounded `poll` inside the
/// C stub, so it is not cancellable mid-flight (bounded by
/// `connect_timeout_ms`).
pub async fn UnixSocketTransport::connect(
  self : UnixSocketTransport,
) -> UnixSocket {
  let path = check_path(self.socket_path)
  let fd = ffi_unix_connect(path, self.connect_timeout_ms)
  if fd < 0 {
    raise connect_error_of(-fd, self.socket_path)
  }
  unix_socket_from_fd(fd)
}

///|
/// Open a connection, write `request`, read until EOF, then close.
/// Convenience for `Connection: close` style request/response.
pub async fn UnixSocketTransport::exchange(
  self : UnixSocketTransport,
  request : Bytes,
) -> Bytes {
  let conn = self.connect()
  defer conn.close()
  conn.write_all(request)
  conn.read_all()
}

///|
/// Write all of `data` to the socket.
pub async fn UnixSocket::write_all(self : UnixSocket, data : Bytes) -> Unit {
  self.stream.write(data)
}

///|
/// Read the next chunk of data, or `None` on EOF.
pub async fn UnixSocket::read_some(
  self : UnixSocket,
  max_len~ : Int32 = 8192,
) -> Bytes? {
  self.stream.read_some(max_len~)
}

///|
/// Read until EOF. For HTTP this pairs with `Connection: close`.
pub async fn UnixSocket::read_all(self : UnixSocket) -> Bytes {
  self.stream.read_all().binary()
}

///|
/// Read exactly `n` bytes or raise.
pub async fn UnixSocket::read_exactly(self : UnixSocket, n : Int32) -> Bytes {
  self.stream.read_exactly(n)
}

///|
/// Read until `delimiter` (inclusive), or `None` on EOF. Returns the
/// bytes as a UTF-8-lossless string — intended for ASCII HTTP headers.
pub async fn UnixSocket::read_until(
  self : UnixSocket,
  delimiter : StringView,
) -> String? {
  self.stream.read_until(delimiter)
}

///|
/// Close the socket; safe to call more than once.
pub fn UnixSocket::close(self : UnixSocket) -> Unit {
  self.stream.close()
}

// --- test/debug support (raw fd plumbing, not part of the stable API) ---

///|
/// Internal/test support: bind+listen a nonblocking unix socket at
/// `path` and return the raw listen fd (caller must `unix_close_fd`).
pub fn unix_listen(path : String, backlog~ : Int32 = 16) -> Int32 raise {
  let fd = ffi_unix_listen(check_path(path), backlog)
  if fd < 0 {
    raise connect_error_of(-fd, path)
  }
  fd
}

///|
/// Internal/test support: nonblocking accept on a `unix_listen` fd.
/// Returns `None` when no connection is pending.
pub fn unix_accept(listen_fd : Int32) -> Int32? raise {
  let fd = ffi_unix_accept(listen_fd)
  if fd < 0 {
    if -fd == ERRNO_EAGAIN {
      None
    } else {
      raise SocketConnectError::ConnectFailed(-fd, "<accept>")
    }
  } else {
    Some(fd)
  }
}

///|
/// Internal/test support: a connected nonblocking unix socketpair as
/// raw fds (caller must `unix_close_fd` or wrap each in `RawFdStream`).
pub fn unix_socketpair() -> (Int32, Int32) raise {
  let packed = ffi_unix_socketpair()
  if packed < 0 {
    raise SocketConnectError::ConnectFailed((-packed).to_int(), "<socketpair>")
  }
  ((packed >> 32).to_int(), packed.to_int())
}

///|
/// Internal/test support: adopt a raw connected fd into a `UnixSocket`.
/// Ownership transfers; do not close `fd` directly afterwards.
pub async fn unix_socket_from_fd(fd : Int32) -> UnixSocket {
  { stream: @raw_fd.RawFdStream::RawFdStream(fd), }
}

///|
/// Internal/test support: close a raw fd not owned by a `UnixSocket`.
pub fn unix_close_fd(fd : Int32) -> Unit raise {
  if ffi_unix_close(fd) < 0 {
    raise SocketConnectError::ConnectFailed(-1, "<close>")
  }
}
