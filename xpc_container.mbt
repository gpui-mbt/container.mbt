// Apple Container XPC container operations (issues 0026-0031).

///|
/// Per-container XPC state held by the public `Container`.
pub struct XpcContainer {
  id : String
  env : Array[String]
}

///|
fn not_found_message(message : String) -> Bool {
  let lower = message.to_lower()
  lower.contains("not found") ||
  lower.contains("notfound") ||
  lower.contains("no such container") ||
  lower.contains("does not exist")
}

///|
fn xpc_error_is_not_found(error : Error) -> Bool {
  match error {
    XpcError::Remote(code~, message~) =>
      not_found_message(code) || not_found_message(message)
    XpcError::MissingKey(..) => false
    _ => false
  }
}

///|
/// `containerList` with an optional ID filter. Returns the parsed
/// `containers` array (empty when the ID is absent).
pub async fn list_containers(id : String?) -> Array[Json] raise {
  let ids : Array[Json] = []
  if id is Some(value) {
    ids.push(Json::string(value))
  }
  let filters = j_obj([("ids", j_arr(ids)), ("labels", j_obj([]))])
  let reply = send(
    service=XPC_SERVICE,
    route="containerList",
    entries=[("listFilters", Data(@utf8.encode(filters.stringify())))],
    timeout_ms=10000,
  )
  defer reply.close()
  let data = reply.data("containers")
  let parsed = parse_json(data, "containerList response")
  match parsed {
    Array(items) => items
    _ => raise XpcError::Malformed(detail="containerList containers is not an array")
  }
}

///|
pub async fn inspect_container(id : String) -> Json? raise {
  let items = list_containers(Some(id))
  if items.length() == 0 {
    None
  } else {
    Some(items[0])
  }
}

///|
fn container_state(item : Json) -> String {
  match item {
    Object(map) =>
      match map.get("status") {
        Some(String(s)) => s
        _ => "unknown"
      }
    _ => "unknown"
  }
}

///|
pub async fn container_is_running(id : String) -> Bool raise {
  match inspect_container(id) {
    Some(item) => container_state(item) == "running"
    None => false
  }
}

///|
async fn get_default_kernel() -> Bytes raise {
  let platform = @utf8.encode("{\"os\":\"linux\",\"architecture\":\"arm64\"}")
  let reply = send(
    service=XPC_SERVICE,
    route="getDefaultKernel",
    entries=[("systemPlatform", Data(platform))],
  )
  defer reply.close()
  reply.data("kernel")
}

///|
/// Create a container. The kernel path is supplied separately so
/// `0047` can pass a custom kernel JSON.
pub async fn create_container(config : Json, kernel : Bytes?) -> Unit raise {
  let cfg = @utf8.encode(config.stringify())
  let kernel = match kernel {
    Some(k) => k
    None => get_default_kernel()
  }
  let options = @utf8.encode("{\"autoRemove\":false}")
  let reply = send(
    service=XPC_SERVICE,
    route="containerCreate",
    entries=[
      ("containerConfig", Data(cfg)),
      ("kernel", Data(kernel)),
      ("containerOptions", Data(options)),
    ],
  )
  reply.close()
}

///|
pub async fn bootstrap_container(id : String) -> Unit raise {
  let reply = send(
    service=XPC_SERVICE,
    route="containerBootstrap",
    entries=[("id", Str(id)), ("dynamicEnv", Data(@utf8.encode("{}")))],
  )
  reply.close()
}

///|
pub async fn start_process(id : String, process_id : String) -> Unit raise {
  let reply = send(
    service=XPC_SERVICE,
    route="containerStartProcess",
    entries=[("id", Str(id)), ("processIdentifier", Str(process_id))],
  )
  reply.close()
}

///|
async fn send_stop_request(id : String, options : Json, timeout_ms : Int) -> Unit raise {
  let reply = send(
    service=XPC_SERVICE,
    route="containerStop",
    entries=[
      ("id", Str(id)),
      ("stopOptions", Data(@utf8.encode(options.stringify()))),
    ],
    timeout_ms~,
  )
  reply.close()
}

///|
pub async fn stop_container(id : String, seconds : Int32?) -> Unit raise {
  // Apple Container 0.12.3 decodes `signal` as an Int32 signal number.
  // SIGKILL=9, SIGTERM=15.
  let signal = match seconds {
    Some(0) => 9
    _ => 15
  }
  let grace = match seconds {
    Some(0) => 0
    Some(n) if n < 0 => 2147483647
    Some(n) => n
    None => 30
  }
  let options = j_obj([
    ("signal", j_int(signal)),
    ("timeoutInSeconds", j_num(grace.to_double())),
  ])
  let timeout_ms = max_i64(60000L, (grace.to_int64() + 30L) * 1000L)
  let timeout_ms = if timeout_ms > 86400000L { 86400000L } else { timeout_ms }
  try
    send_stop_request(id, options, timeout_ms.to_int()) catch {
    XpcError::Remote(code~, message~) => {
      if not_found_message(code) || not_found_message(message) ||
        message.to_lower().contains("not running") ||
        message.to_lower().contains("already stopped") {
        return
      }
      // Apple Container 0.12.x decodes `signal` as an Int32; newer
      // versions/upstream used a string. Retry the other spelling once
      // when the server explicitly rejects the signal field.
      if message.contains("signal") {
        let legacy = j_obj([
          ("signal", j_str(match seconds {
            Some(0) => "SIGKILL"
            _ => "SIGTERM"
          })),
          ("timeoutInSeconds", j_num(grace.to_double())),
        ])
        send_stop_request(id, legacy, timeout_ms.to_int())
      } else {
        raise XpcError::Remote(code~, message~)
      }
    }
    e => raise e
  } noraise {
    _ => ()
  }
}

///|
fn max_i64(a : Int64, b : Int64) -> Int64 {
  if a > b { a } else { b }
}

///|
pub async fn remove_container(id : String, force : Bool) -> Unit raise {
  try
    send(
      service=XPC_SERVICE,
      route="containerDelete",
      entries=[("id", Str(id)), ("forceDelete", Bool(force))],
    ) catch {
    e =>
      if xpc_error_is_not_found(e) {
        return
      } else {
        raise e
      }
  } noraise {
    reply => reply.close()
  }
}

///|
pub async fn wait_process(
  id : String,
  process_id : String,
  timeout_ms : Int,
) -> Int64 raise {
  let reply = send(
    service=XPC_SERVICE,
    route="containerWait",
    entries=[("id", Str(id)), ("processIdentifier", Str(process_id))],
    timeout_ms~,
  )
  defer reply.close()
  reply.int64("exitCode")
}

///|
pub async fn logs_fds(id : String) -> (Int32, Int32) raise {
  let reply = send(
    service=XPC_SERVICE,
    route="containerLogs",
    entries=[("id", Str(id))],
  )
  defer reply.close()
  reply.log_fds()
}

///|
/// Copy one host path into the container (`containerCopyIn`). The host
/// path must be absolute UTF-8; the caller owns the source file.
pub async fn copy_in(
  id : String,
  source_path : String,
  destination_path : String,
  mode : Int32,
) -> Unit raise {
  guard source_path.has_prefix("/") else {
    raise XpcError::Malformed(detail="copy source must be absolute: \{source_path}")
  }
  let reply = send(
    service=XPC_SERVICE,
    route="containerCopyIn",
    entries=[
      ("id", Str(id)),
      ("sourcePath", Str(source_path)),
      ("destinationPath", Str(destination_path)),
      ("fileMode", UInt64(mode.to_uint64())),
      ("createParents", Bool(true)),
    ],
  )
  reply.close()
}

///|
let exec_counter_state : Ref[Int] = { val: 0, }

///|
fn exec_counter() -> Int {
  exec_counter_state.val = exec_counter_state.val + 1
  exec_counter_state.val
}

///|
fn next_exec_id() -> String {
  "exec-\{@async.now()}-\{exec_counter()}"
}

///|
fn process_config(executable : String, args : Array[String], env : Array[String]) -> Json {
  j_obj([
    ("executable", j_str(executable)),
    ("arguments", j_str_array(args)),
    ("environment", j_str_array(env)),
    ("workingDirectory", j_str("/")),
    ("terminal", j_bool(false)),
    ("user", j_obj([("id", j_obj([("uid", j_int(0)), ("gid", j_int(0))]))])),
    ("supplementalGroups", j_arr([])),
    ("rlimits", j_arr([])),
  ])
}

///|
/// Execute a command through `containerCreateProcess` /
/// `containerStartProcess` / `containerWait`. Reads stdout/stderr
/// concurrently with the wait to avoid pipe-buffer deadlocks.
pub async fn exec_process(
  container : XpcContainer,
  command : Array[String],
  extra_env : Array[(String, String)],
) -> ProcessOutput raise {
  guard command.length() > 0 else {
    raise XpcError::Malformed(detail="exec requires at least one argument")
  }
  let executable = command[0]
  let arguments : Array[String] = if command.length() > 1 {
    command[1:].to_owned()
  } else {
    []
  }
  let env = container.env.copy()
  for (key, value) in extra_env {
    env.push("\{key}=\{value}")
  }
  let (out_read, out_write) = pipe_pair()
  let (err_read, err_write) = pipe_pair()
  let process_id = next_exec_id()
  let cfg = process_config(executable, arguments, env)
  let sent : XpcReply = {
    errdefer {
      let _ = moonbit_close_fd(out_read)
      let _ = moonbit_close_fd(err_read)
      let _ = moonbit_close_fd(out_write)
      let _ = moonbit_close_fd(err_write)
    }
    send(
      service=XPC_SERVICE,
      route="containerCreateProcess",
      entries=[
        ("id", Str(container.id)),
        ("processIdentifier", Str(process_id)),
        ("processConfig", Data(@utf8.encode(cfg.stringify()))),
        ("stdout", Fd(out_write)),
        ("stderr", Fd(err_write)),
      ],
    )
  }
  sent.close()
  // XPC duplicated the write ends; close our copies so readers see EOF.
  let _ = moonbit_close_fd(out_write)
  let _ = moonbit_close_fd(err_write)

  let out_stream = @raw_fd.RawFdStream::RawFdStream(out_read)
  let err_stream = @raw_fd.RawFdStream::RawFdStream(err_read)
  let stdout : Ref[Bytes] = { val: b"", }
  let stderr : Ref[Bytes] = { val: b"", }
  let wait_result : Ref[Int64?] = { val: None, }
  let wait_error : Ref[Error?] = { val: None, }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      stdout.val = out_stream.read_all().binary()
      out_stream.close()
    })
    group.spawn_bg(() => {
      stderr.val = err_stream.read_all().binary()
      err_stream.close()
    })
    group.spawn_bg(() => {
      try wait_process(container.id, process_id, XPC_LONG_TIMEOUT_MS) catch {
        e => wait_error.val = Some(e)
      } noraise {
        code => wait_result.val = Some(code)
      }
    })
    try start_process(container.id, process_id) catch {
      e => wait_error.val = Some(e)
    } noraise {
      _ => ()
    }
  })
  match wait_error.val {
    Some(e) => raise e
    None => ()
  }
  let exit_code = match wait_result.val {
    Some(code) => code
    None => raise XpcError::Malformed(detail="containerWait returned no exit code")
  }
  let out = stdout.val
  let err = stderr.val
  guard out.length() <= 67108864 && err.length() <= 67108864 else {
    raise XpcError::Malformed(detail="exec output exceeds the 64 MiB bound")
  }
  {
    exit_code: exit_code.to_int(),
    stdout: @utf8.decode_lossy(out),
    stderr: @utf8.decode_lossy(err),
  }
}

///|
/// Live XPC containers keyed by ID. The public `Container` stores no
/// adapter-specific field, so tests and callers that construct it by
/// hand keep working; XPC operations look up this registry.
let xpc_registry : Map[String, XpcContainer] = Map([])

///|
pub fn xpc_for(id : String) -> XpcContainer? {
  xpc_registry.get(id)
}

///|
pub fn register_xpc(container : XpcContainer) -> Unit {
  xpc_registry[container.id] = container
}

///|
pub fn unregister_xpc(id : String) -> Unit {
  let _ = xpc_registry.remove(id)
}

///|
/// Read the two XPC log FDs for a bounded window. The first FD carries
/// the application's stdout/stderr (Apple multiplexes them); the second
/// is the VM bootlog and is returned as `stderr` only as a diagnostic.
pub async fn read_logs(
  container : XpcContainer,
  timeout_ms : Int32,
  idle_ms : Int32,
) -> ProcessOutput raise {
  let (out_fd, boot_fd) = logs_fds(container.id)
  let _ = container_set_nonblock(out_fd)
  let _ = container_set_nonblock(boot_fd)
  let out_stream = @raw_fd.RawFdStream::RawFdStream(out_fd)
  let boot_stream = @raw_fd.RawFdStream::RawFdStream(boot_fd)
  let out : Array[Byte] = []
  let boot : Array[Byte] = []
  let deadline = @async.now() + timeout_ms.to_int64()
  let idle_deadline = @async.now() + idle_ms.to_int64()
  let mut last_data = @async.now()
  while @async.now() < deadline {
    let mut got = false
    let chunk = try out_stream.read_some() catch { _ => None } noraise { c => c }
    if chunk is Some(bytes) {
      if bytes.length() > 0 {
        out.append(bytes.to_array())
        got = true
      }
    }
    let chunk2 = try boot_stream.read_some() catch { _ => None } noraise { c => c }
    if chunk2 is Some(bytes) {
      if bytes.length() > 0 {
        boot.append(bytes.to_array())
        got = true
      }
    }
    if got {
      last_data = @async.now()
    } else if @async.now() - last_data >= idle_ms.to_int64() &&
      @async.now() >= idle_deadline {
      break
    }
    guard out.length() <= 67108864 && boot.length() <= 67108864 else {
      out_stream.close()
      boot_stream.close()
      raise XpcError::Malformed(detail="logs exceed the 64 MiB bound")
    }
    @async.sleep(10)
  }
  out_stream.close()
  boot_stream.close()
  {
    exit_code: 0,
    stdout: @utf8.decode_lossy(Bytes::from_array(out)),
    stderr: @utf8.decode_lossy(Bytes::from_array(boot)),
  }
}
