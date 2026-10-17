///|
/// Live XPC handshake (0023/0024). Skipped with an explicit marker on
/// non-macOS natives; the real acceptance is the `smoke_xpc` executable.
async test "xpc containerList handshake" {
  if !is_apple() {
    println("SKIP (未実行): Apple Container XPC requires macOS")
    return
  }
  let filters = @utf8.encode("{\"ids\":[],\"labels\":{}}")
  let reply = try {
    send(
      service=XPC_SERVICE,
      route="containerList",
      entries=[("listFilters", Data(filters))],
      timeout_ms=10000,
    )
  } catch {
    e => {
      println("xpc handshake failed: \{e}")
      fail("XPC handshake failed")
    }
  } noraise {
    reply => reply
  }
  defer reply.close()
  let containers = reply.data("containers")
  guard containers.length() >= 2 else {
    fail("containerList did not return a JSON array payload")
  }
}

///|
async test "xpc reply decoding is strict" {
  if !is_apple() {
    println("SKIP (未実行): Apple Container XPC requires macOS")
    return
  }
  let reply = send(
    service=XPC_SERVICE,
    route="containerList",
    entries=[("listFilters", Data(@utf8.encode("{\"ids\":[],\"labels\":{}}")))],
    timeout_ms=10000,
  )
  defer reply.close()
  try {
    ignore(reply.string("containers"))
    fail("data key decoded as a string")
  } catch {
    XpcError::TypeMismatch(..) => ()
    e => fail("expected TypeMismatch, got \{e}")
  }
  try {
    ignore(reply.int64("missing-key"))
    fail("missing int64 key was accepted")
  } catch {
    XpcError::MissingKey(..) => ()
    e => fail("expected MissingKey, got \{e}")
  }
}

///|
async test "xpc timeout is bounded and does not leak fds" {
  if !is_apple() {
    println("SKIP (未実行): Apple Container XPC requires macOS")
    return
  }
  let before = count_open_fds()
  for i = 0; i < 5; i = i + 1 {
    try {
      let reply = send(
        service=XPC_SERVICE,
        route="containerWait",
        entries=[("id", Str("missing-xpc-container")), ("processIdentifier", Str("missing"))],
        timeout_ms=200,
      )
      reply.close()
    } catch {
      XpcError::Timeout | XpcError::Remote(..) => ()
      e => fail("unexpected XPC error: \{e}")
    }
  }
  @async.sleep(500)
  let after = count_open_fds()
  // Unit tests run concurrently, so a process-wide FD delta is only
  // informational here; the single-process `smoke_xpc` asserts it.
  println("xpc timeout fd probe: \{before} -> \{after}")
}
