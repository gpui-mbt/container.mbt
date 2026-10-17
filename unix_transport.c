// Unix-domain socket primitives for the Docker Engine transport.
// All functions return a non-negative file descriptor / 0 on success
// and a negative errno value on failure. The MoonBit side classifies
// the errno into typed errors.
#define _GNU_SOURCE /* accept4, SOCK_CLOEXEC, SOCK_NONBLOCK */
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <moonbit.h>

static int32_t fail_errno(int fd, int err) {
  if (fd >= 0) {
    int saved = err;
    close(fd);
    err = saved;
  }
  return -err;
}

// Connect to `path` (NUL-terminated UTF-8, filesystem unix socket).
// The socket is created nonblocking; if connect() reports EINPROGRESS
// we poll for writability up to `timeout_ms` and then read SO_ERROR.
MOONBIT_FFI_EXPORT
int32_t moonbit_container_unix_connect(const char *path, int32_t timeout_ms) {
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
  if (fd < 0) return -errno;
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  size_t path_len = strlen(path);
  if (path_len >= sizeof(addr.sun_path)) return fail_errno(fd, ENAMETOOLONG);
  memcpy(addr.sun_path, path, path_len);
  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) return fd;
  int err = errno;
  if (err != EINPROGRESS) return fail_errno(fd, err);
  struct pollfd pfd = { fd, POLLOUT, 0 };
  int rc;
  do {
    rc = poll(&pfd, 1, (int)timeout_ms);
  } while (rc < 0 && errno == EINTR);
  if (rc == 0) return fail_errno(fd, ETIMEDOUT);
  if (rc < 0) return fail_errno(fd, errno);
  socklen_t len = (socklen_t)sizeof(err);
  if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) < 0)
    return fail_errno(fd, errno);
  if (err != 0) return fail_errno(fd, err);
  return fd;
}

// Bind + listen a nonblocking unix socket at `path`. The caller owns the fd.
MOONBIT_FFI_EXPORT
int32_t moonbit_container_unix_listen(const char *path, int32_t backlog) {
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
  if (fd < 0) return -errno;
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  size_t path_len = strlen(path);
  if (path_len >= sizeof(addr.sun_path)) return fail_errno(fd, ENAMETOOLONG);
  memcpy(addr.sun_path, path, path_len);
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0)
    return fail_errno(fd, errno);
  if (listen(fd, (int)backlog) < 0) return fail_errno(fd, errno);
  return fd;
}

// Nonblocking accept on a listen fd created by moonbit_container_unix_listen.
// Returns -EAGAIN when no connection is pending.
MOONBIT_FFI_EXPORT
int32_t moonbit_container_unix_accept(int32_t listen_fd) {
  int fd;
  do {
    fd = accept4((int)listen_fd, NULL, NULL, SOCK_CLOEXEC | SOCK_NONBLOCK);
  } while (fd < 0 && errno == EINTR);
  if (fd < 0) return -errno;
  return fd;
}

// Connected nonblocking unix socketpair, packed as fd0 << 32 | fd1.
MOONBIT_FFI_EXPORT
int64_t moonbit_container_unix_socketpair(void) {
  int sv[2];
  if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0, sv) <
      0)
    return -(int64_t)errno;
  return ((int64_t)(uint32_t)sv[0] << 32) | (int64_t)(uint32_t)sv[1];
}

MOONBIT_FFI_EXPORT
int32_t moonbit_container_unix_close(int32_t fd) {
  int rc;
  do {
    rc = close((int)fd);
  } while (rc < 0 && errno == EINTR);
  if (rc < 0) return -errno;
  return 0;
}
