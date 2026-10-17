// Apple Container XPC bridge (native stub).
//
// The real implementation is compiled only on macOS; Linux builds only
// see the small platform helpers and XPC stubs returning ENOTSUP.
// Keeping the file in the package native-stub list on every platform
// lets MoonBit declare a single FFI surface without conditional imports.
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <moonbit.h>

MOONBIT_FFI_EXPORT
int32_t moonbit_container_is_apple(void) {
#ifdef __APPLE__
  return 1;
#else
  return 0;
#endif
}

// Count open file descriptors by probing the descriptor table. Used by
// the XPC acceptance smokes to assert FD ownership (0029/0032).
MOONBIT_FFI_EXPORT
int32_t moonbit_container_count_open_fds(void) {
  long max = sysconf(_SC_OPEN_MAX);
  if (max < 0 || max > 65536) max = 65536;
  int32_t count = 0;
  for (int fd = 0; fd < (int)max; fd++) {
    if (fcntl(fd, F_GETFD) != -1) count++;
  }
  return count;
}

// Pipe pair for exec stdout/stderr capture, packed as read << 32 | write.
// Returns a negative errno on failure.
MOONBIT_FFI_EXPORT
int64_t moonbit_container_pipe_pair(void) {
  int fds[2];
  if (pipe(fds) < 0) return -(int64_t)errno;
  return ((int64_t)(uint32_t)fds[0] << 32) | (int64_t)(uint32_t)fds[1];
}

#ifdef __APPLE__

#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <stdatomic.h>

#define XPC_CTX_PENDING 0
#define XPC_CTX_READY 1
#define XPC_CTX_ABANDONED 2
#define XPC_CTX_TAKEN 3

typedef struct {
  _Atomic int state;
  _Atomic int refs;
  xpc_object_t reply;
} moonbit_xpc_ctx;

static void moonbit_xpc_ctx_unref(moonbit_xpc_ctx *ctx) {
  if (atomic_fetch_sub_explicit(&ctx->refs, 1, memory_order_acq_rel) == 1) {
    if (ctx->reply) xpc_release(ctx->reply);
    free(ctx);
  }
}

MOONBIT_FFI_EXPORT
void *moonbit_xpc_connect(const char *service) {
  xpc_connection_t conn = xpc_connection_create_mach_service(service, NULL, 0);
  if (!conn) return NULL;
  xpc_connection_set_event_handler(conn, ^(xpc_object_t _){});
  xpc_connection_activate(conn);
  return (void *)conn;
}

MOONBIT_FFI_EXPORT
void moonbit_xpc_connection_cancel(void *conn) {
  if (conn) xpc_connection_cancel((xpc_connection_t)conn);
}

MOONBIT_FFI_EXPORT
void moonbit_xpc_connection_release(void *conn) {
  if (conn) xpc_release((xpc_connection_t)conn);
}

MOONBIT_FFI_EXPORT
void *moonbit_xpc_message_create(void) {
  return (void *)xpc_dictionary_create(NULL, NULL, 0);
}

MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_message_is_null(void *msg) { return msg == NULL ? 1 : 0; }

MOONBIT_FFI_EXPORT
void moonbit_xpc_message_release(void *msg) {
  if (msg) xpc_release((xpc_object_t)msg);
}

MOONBIT_FFI_EXPORT
void moonbit_xpc_set_string(void *msg, const char *key, const char *value) {
  xpc_dictionary_set_string((xpc_object_t)msg, key, value);
}

MOONBIT_FFI_EXPORT
void moonbit_xpc_set_data(void *msg, const char *key, const void *data,
                          int32_t len) {
  xpc_dictionary_set_data((xpc_object_t)msg, key, data, (size_t)len);
}

MOONBIT_FFI_EXPORT
void moonbit_xpc_set_int64(void *msg, const char *key, int64_t value) {
  xpc_dictionary_set_int64((xpc_object_t)msg, key, value);
}

MOONBIT_FFI_EXPORT
void moonbit_xpc_set_uint64(void *msg, const char *key, uint64_t value) {
  xpc_dictionary_set_uint64((xpc_object_t)msg, key, value);
}

MOONBIT_FFI_EXPORT
void moonbit_xpc_set_bool(void *msg, const char *key, int32_t value) {
  xpc_dictionary_set_bool((xpc_object_t)msg, key, value != 0);
}

MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_set_fd(void *msg, const char *key, int32_t fd) {
  xpc_object_t xfd = xpc_fd_create((int)fd);
  if (!xfd) return 0;
  xpc_dictionary_set_value((xpc_object_t)msg, key, xfd);
  xpc_release(xfd);
  return 1;
}

// Non-blocking send: the reply handler records the retained reply in a
// shared context. MoonBit polls with its async loop instead of blocking
// the event loop for up to 24 hours on `containerWait`.
MOONBIT_FFI_EXPORT
void *moonbit_xpc_send_async(void *conn, void *msg) {
  moonbit_xpc_ctx *ctx = calloc(1, sizeof(*ctx));
  if (!ctx) return NULL;
  atomic_store_explicit(&ctx->state, XPC_CTX_PENDING, memory_order_relaxed);
  atomic_store_explicit(&ctx->refs, 2, memory_order_relaxed);
  xpc_connection_send_message_with_reply(
      (xpc_connection_t)conn, (xpc_object_t)msg, NULL,
      ^(xpc_object_t reply) {
        xpc_object_t retained = reply ? xpc_retain(reply) : NULL;
        int expected = XPC_CTX_PENDING;
        if (atomic_compare_exchange_strong_explicit(
                &ctx->state, &expected, XPC_CTX_READY, memory_order_acq_rel,
                memory_order_acquire)) {
          ctx->reply = retained;
        } else if (retained) {
          // The waiter timed out and abandoned the context.
          xpc_release(retained);
        }
        moonbit_xpc_ctx_unref(ctx);
      });
  return ctx;
}

// 0 = pending, 1 = ready, 2 = abandoned/taken.
MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_poll(void *raw) {
  moonbit_xpc_ctx *ctx = (moonbit_xpc_ctx *)raw;
  int state = atomic_load_explicit(&ctx->state, memory_order_acquire);
  if (state == XPC_CTX_READY) return 1;
  if (state == XPC_CTX_ABANDONED || state == XPC_CTX_TAKEN) return 2;
  return 0;
}

// Transfers the reply to the caller and consumes the caller's context
// reference. Returns NULL when the context is not ready.
MOONBIT_FFI_EXPORT
void *moonbit_xpc_take_reply(void *raw) {
  moonbit_xpc_ctx *ctx = (moonbit_xpc_ctx *)raw;
  int expected = XPC_CTX_READY;
  if (!atomic_compare_exchange_strong_explicit(
          &ctx->state, &expected, XPC_CTX_TAKEN, memory_order_acq_rel,
          memory_order_acquire)) {
    return NULL;
  }
  xpc_object_t reply = ctx->reply;
  ctx->reply = NULL;
  moonbit_xpc_ctx_unref(ctx);
  return reply;
}

// Give up waiting. A late reply is released by the reply handler.
MOONBIT_FFI_EXPORT
void moonbit_xpc_abandon(void *raw) {
  moonbit_xpc_ctx *ctx = (moonbit_xpc_ctx *)raw;
  int state = atomic_load_explicit(&ctx->state, memory_order_acquire);
  if (state == XPC_CTX_PENDING) {
    int expected = XPC_CTX_PENDING;
    if (atomic_compare_exchange_strong_explicit(
            &ctx->state, &expected, XPC_CTX_ABANDONED, memory_order_acq_rel,
            memory_order_acquire)) {
      moonbit_xpc_ctx_unref(ctx);
      return;
    }
    state = atomic_load_explicit(&ctx->state, memory_order_acquire);
  }
  if (state == XPC_CTX_READY) {
    int expected = XPC_CTX_READY;
    if (atomic_compare_exchange_strong_explicit(
            &ctx->state, &expected, XPC_CTX_TAKEN, memory_order_acq_rel,
            memory_order_acquire)) {
      xpc_object_t reply = ctx->reply;
      ctx->reply = NULL;
      if (reply) xpc_release(reply);
    }
  }
  moonbit_xpc_ctx_unref(ctx);
}

MOONBIT_FFI_EXPORT
void moonbit_xpc_reply_release(void *reply) {
  if (reply) xpc_release((xpc_object_t)reply);
}

MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_is_null(void *ptr) { return ptr == NULL ? 1 : 0; }

MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_context_is_null(void *ptr) { return ptr == NULL ? 1 : 0; }

MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_reply_is_null(void *ptr) { return ptr == NULL ? 1 : 0; }

MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_is_error(void *reply) {
  return reply && xpc_get_type((xpc_object_t)reply) == XPC_TYPE_ERROR;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_type_of(void *reply, const char *key) {
  if (!reply)
    return 0;
  xpc_object_t v = xpc_dictionary_get_value((xpc_object_t)reply, key);
  if (!v)
    return 0;
  xpc_type_t t = xpc_get_type(v);
  if (t == XPC_TYPE_STRING) return 1;
  if (t == XPC_TYPE_DATA) return 2;
  if (t == XPC_TYPE_INT64) return 3;
  if (t == XPC_TYPE_UINT64) return 4;
  if (t == XPC_TYPE_BOOL) return 5;
  if (t == XPC_TYPE_ARRAY) return 6;
  if (t == XPC_TYPE_DICTIONARY) return 7;
  return 8;
}

static moonbit_bytes_t copy_bytes(const void *src, size_t len) {
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)len, 0);
  if (len && src)
    memcpy(out, src, len);
  return out;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t moonbit_xpc_copy_string(void *reply, const char *key) {
  if (!reply)
    return copy_bytes(NULL, 0);
  xpc_object_t v = xpc_dictionary_get_value((xpc_object_t)reply, key);
  if (!v || xpc_get_type(v) != XPC_TYPE_STRING)
    return copy_bytes(NULL, 0);
  const char *s = xpc_string_get_string_ptr(v);
  return copy_bytes(s, s ? strlen(s) : 0);
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t moonbit_xpc_copy_data(void *reply, const char *key) {
  if (!reply)
    return copy_bytes(NULL, 0);
  xpc_object_t v = xpc_dictionary_get_value((xpc_object_t)reply, key);
  if (!v || xpc_get_type(v) != XPC_TYPE_DATA)
    return copy_bytes(NULL, 0);
  return copy_bytes(xpc_data_get_bytes_ptr(v), xpc_data_get_length(v));
}

MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_get_int64(void *reply, const char *key, int64_t *out) {
  if (!reply || !out)
    return 0;
  xpc_object_t v = xpc_dictionary_get_value((xpc_object_t)reply, key);
  if (!v || xpc_get_type(v) != XPC_TYPE_INT64)
    return 0;
  *out = xpc_int64_get_value(v);
  return 1;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_get_uint64(void *reply, const char *key, uint64_t *out) {
  if (!reply || !out)
    return 0;
  xpc_object_t v = xpc_dictionary_get_value((xpc_object_t)reply, key);
  if (!v || xpc_get_type(v) != XPC_TYPE_UINT64)
    return 0;
  *out = xpc_uint64_get_value(v);
  return 1;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_get_bool(void *reply, const char *key, int32_t *out) {
  if (!reply || !out)
    return 0;
  xpc_object_t v = xpc_dictionary_get_value((xpc_object_t)reply, key);
  if (!v || xpc_get_type(v) != XPC_TYPE_BOOL)
    return 0;
  *out = xpc_bool_get_value(v) ? 1 : 0;
  return 1;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t moonbit_xpc_error_description(void *reply) {
  if (!reply || xpc_get_type((xpc_object_t)reply) != XPC_TYPE_ERROR)
    return copy_bytes(NULL, 0);
  const char *s =
      xpc_dictionary_get_string((xpc_object_t)reply, _xpc_error_key_description);
  return copy_bytes(s, s ? strlen(s) : 0);
}

// Copy the two log FDs. Returns the number of valid FDs written, or -1
// when the "logs" key is not an array.
MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_get_log_fds(void *reply, int32_t *fd0, int32_t *fd1) {
  if (!reply || !fd0 || !fd1)
    return -1;
  xpc_object_t arr = xpc_dictionary_get_value((xpc_object_t)reply, "logs");
  if (!arr || xpc_get_type(arr) != XPC_TYPE_ARRAY)
    return -1;
  size_t count = xpc_array_get_count(arr);
  if (count > 2)
    count = 2;
  if (count >= 1)
    *fd0 = xpc_array_dup_fd(arr, 0);
  else
    *fd0 = -1;
  if (count >= 2)
    *fd1 = xpc_array_dup_fd(arr, 1);
  else
    *fd1 = -1;
  return (int32_t)count;
}

#else  // !__APPLE__

MOONBIT_FFI_EXPORT
void *moonbit_xpc_connect(const char *service) {
  (void)service;
  return NULL;
}
MOONBIT_FFI_EXPORT
void moonbit_xpc_connection_cancel(void *conn) { (void)conn; }
MOONBIT_FFI_EXPORT
void moonbit_xpc_connection_release(void *conn) { (void)conn; }
MOONBIT_FFI_EXPORT
void *moonbit_xpc_message_create(void) { return NULL; }
MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_message_is_null(void *msg) { (void)msg; return 1; }
MOONBIT_FFI_EXPORT
void moonbit_xpc_message_release(void *msg) { (void)msg; }
MOONBIT_FFI_EXPORT
void moonbit_xpc_set_string(void *msg, const char *key, const char *value) {
  (void)msg; (void)key; (void)value;
}
MOONBIT_FFI_EXPORT
void moonbit_xpc_set_data(void *msg, const char *key, const void *data,
                          int32_t len) {
  (void)msg; (void)key; (void)data; (void)len;
}
MOONBIT_FFI_EXPORT
void moonbit_xpc_set_int64(void *msg, const char *key, int64_t value) {
  (void)msg; (void)key; (void)value;
}
MOONBIT_FFI_EXPORT
void moonbit_xpc_set_uint64(void *msg, const char *key, uint64_t value) {
  (void)msg; (void)key; (void)value;
}
MOONBIT_FFI_EXPORT
void moonbit_xpc_set_bool(void *msg, const char *key, int32_t value) {
  (void)msg; (void)key; (void)value;
}
MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_set_fd(void *msg, const char *key, int32_t fd) {
  (void)msg; (void)key; (void)fd; return 0;
}
MOONBIT_FFI_EXPORT
void *moonbit_xpc_send_async(void *conn, void *msg) {
  (void)conn; (void)msg; return NULL;
}
MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_poll(void *ctx) { (void)ctx; return 2; }
MOONBIT_FFI_EXPORT
void *moonbit_xpc_take_reply(void *ctx) { (void)ctx; return NULL; }
MOONBIT_FFI_EXPORT
void moonbit_xpc_abandon(void *ctx) { (void)ctx; }
MOONBIT_FFI_EXPORT
void moonbit_xpc_reply_release(void *reply) { (void)reply; }
MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_is_null(void *ptr) { (void)ptr; return 1; }
MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_context_is_null(void *ptr) { (void)ptr; return 1; }
MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_reply_is_null(void *ptr) { (void)ptr; return 1; }
MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_is_error(void *reply) { (void)reply; return 1; }
MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_type_of(void *reply, const char *key) {
  (void)reply; (void)key; return 0;
}
MOONBIT_FFI_EXPORT
moonbit_bytes_t moonbit_xpc_copy_string(void *reply, const char *key) {
  (void)reply; (void)key; return moonbit_make_bytes(0, 0);
}
MOONBIT_FFI_EXPORT
moonbit_bytes_t moonbit_xpc_copy_data(void *reply, const char *key) {
  (void)reply; (void)key; return moonbit_make_bytes(0, 0);
}
MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_get_int64(void *reply, const char *key, int64_t *out) {
  (void)reply; (void)key; (void)out; return 0;
}
MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_get_uint64(void *reply, const char *key, uint64_t *out) {
  (void)reply; (void)key; (void)out; return 0;
}
MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_get_bool(void *reply, const char *key, int32_t *out) {
  (void)reply; (void)key; (void)out; return 0;
}
MOONBIT_FFI_EXPORT
moonbit_bytes_t moonbit_xpc_error_description(void *reply) {
  (void)reply; return moonbit_make_bytes(0, 0);
}
MOONBIT_FFI_EXPORT
int32_t moonbit_xpc_get_log_fds(void *reply, int32_t *fd0, int32_t *fd1) {
  (void)reply; (void)fd0; (void)fd1; return -1;
}

#endif
