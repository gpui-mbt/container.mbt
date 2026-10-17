// Raw Apple Container XPC FFI declarations. The C symbols are no-op
// stubs on non-Apple natives; `XpcBridge` checks the platform before
// using them.
#external
priv type XpcConnectionPtr

#external
priv type XpcMessagePtr

#external
priv type XpcContextPtr

#external
priv type XpcReplyPtr

///|
#borrow(service)
extern "C" fn xpc_connect(service : Bytes) -> XpcConnectionPtr = "moonbit_xpc_connect"

///|
extern "C" fn xpc_connection_cancel(conn : XpcConnectionPtr) = "moonbit_xpc_connection_cancel"

///|
extern "C" fn xpc_connection_release(conn : XpcConnectionPtr) = "moonbit_xpc_connection_release"

///|
extern "C" fn xpc_message_create() -> XpcMessagePtr = "moonbit_xpc_message_create"

///|
extern "C" fn xpc_message_is_null(msg : XpcMessagePtr) -> Int32 = "moonbit_xpc_message_is_null"

///|
extern "C" fn xpc_message_release(msg : XpcMessagePtr) = "moonbit_xpc_message_release"

///|
#borrow(msg, key, value)
extern "C" fn xpc_set_string(msg : XpcMessagePtr, key : Bytes, value : Bytes) = "moonbit_xpc_set_string"

///|
#borrow(msg, key, data)
extern "C" fn xpc_set_data(msg : XpcMessagePtr, key : Bytes, data : Bytes, len : Int32) = "moonbit_xpc_set_data"

///|
#borrow(msg, key)
extern "C" fn xpc_set_int64(msg : XpcMessagePtr, key : Bytes, value : Int64) = "moonbit_xpc_set_int64"

///|
#borrow(msg, key)
extern "C" fn xpc_set_uint64(msg : XpcMessagePtr, key : Bytes, value : UInt64) = "moonbit_xpc_set_uint64"

///|
#borrow(msg, key)
extern "C" fn xpc_set_bool(msg : XpcMessagePtr, key : Bytes, value : Bool) = "moonbit_xpc_set_bool"

///|
#borrow(msg, key)
extern "C" fn xpc_set_fd(msg : XpcMessagePtr, key : Bytes, fd : Int32) -> Int32 = "moonbit_xpc_set_fd"

///|
extern "C" fn xpc_send_async(conn : XpcConnectionPtr, msg : XpcMessagePtr) -> XpcContextPtr = "moonbit_xpc_send_async"

///|
extern "C" fn xpc_poll(ctx : XpcContextPtr) -> Int32 = "moonbit_xpc_poll"

///|
extern "C" fn xpc_take_reply(ctx : XpcContextPtr) -> XpcReplyPtr = "moonbit_xpc_take_reply"

///|
extern "C" fn xpc_abandon(ctx : XpcContextPtr) = "moonbit_xpc_abandon"

///|
extern "C" fn xpc_reply_release(reply : XpcReplyPtr) = "moonbit_xpc_reply_release"

///|
extern "C" fn xpc_is_null(ptr : XpcConnectionPtr) -> Int32 = "moonbit_xpc_is_null"

///|
extern "C" fn xpc_context_is_null(ptr : XpcContextPtr) -> Int32 = "moonbit_xpc_context_is_null"

///|
extern "C" fn xpc_reply_is_null(ptr : XpcReplyPtr) -> Int32 = "moonbit_xpc_reply_is_null"

///|
extern "C" fn xpc_is_error(reply : XpcReplyPtr) -> Int32 = "moonbit_xpc_is_error"

///|
#borrow(key)
extern "C" fn xpc_type_of(reply : XpcReplyPtr, key : Bytes) -> Int32 = "moonbit_xpc_type_of"

///|
#borrow(key)
extern "C" fn xpc_copy_string(reply : XpcReplyPtr, key : Bytes) -> Bytes = "moonbit_xpc_copy_string"

///|
#borrow(key)
extern "C" fn xpc_copy_data(reply : XpcReplyPtr, key : Bytes) -> Bytes = "moonbit_xpc_copy_data"

///|
#borrow(key, out)
extern "C" fn xpc_get_int64(reply : XpcReplyPtr, key : Bytes, out : Ref[Int64]) -> Int32 = "moonbit_xpc_get_int64"

///|
#borrow(key, out)
extern "C" fn xpc_get_uint64(reply : XpcReplyPtr, key : Bytes, out : Ref[UInt64]) -> Int32 = "moonbit_xpc_get_uint64"

///|
#borrow(key, out)
extern "C" fn xpc_get_bool(reply : XpcReplyPtr, key : Bytes, out : Ref[Int32]) -> Int32 = "moonbit_xpc_get_bool"

///|
extern "C" fn xpc_error_description(reply : XpcReplyPtr) -> Bytes = "moonbit_xpc_error_description"

///|
#borrow(reply, fd0, fd1)
extern "C" fn xpc_get_log_fds(
  reply : XpcReplyPtr,
  fd0 : Ref[Int32],
  fd1 : Ref[Int32],
) -> Int32 = "moonbit_xpc_get_log_fds"

///|
extern "C" fn container_is_apple() -> Int32 = "moonbit_container_is_apple"

///|
extern "C" fn container_count_open_fds() -> Int32 = "moonbit_container_count_open_fds"

///|
extern "C" fn container_pipe_pair() -> Int64 = "moonbit_container_pipe_pair"

///|
extern "C" fn container_set_nonblock(fd : Int32) -> Int32 = "moonbit_container_set_nonblock"
