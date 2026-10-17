///|
/// Docker HEALTHCHECK builder (issue 0037), mirroring upstream
/// `Healthcheck`. `test` is `NONE`/`CMD-SHELL`/`CMD` argv; durations
/// are milliseconds and serialize as nanoseconds in create JSON.
pub struct Healthcheck {
  test_args : Array[String]
  mut interval_ms : Int32?
  mut timeout_ms : Int32?
  mut retries : Int32?
  mut start_period_ms : Int32?
  mut start_interval_ms : Int32?
}

///|
/// `CMD-SHELL <command>` — run inside the container's default shell.
pub fn Healthcheck::cmd_shell(command : String) -> Healthcheck {
  {
    test_args: ["CMD-SHELL", command],
    interval_ms: None,
    timeout_ms: None,
    retries: None,
    start_period_ms: None,
    start_interval_ms: None,
  }
}

///|
/// `CMD <argv...>` — exec form.
pub fn Healthcheck::cmd(command : Array[String]) -> Healthcheck {
  {
    test_args: ["CMD", ..command],
    interval_ms: None,
    timeout_ms: None,
    retries: None,
    start_period_ms: None,
    start_interval_ms: None,
  }
}

///|
/// `NONE` — disable any inherited healthcheck.
pub fn Healthcheck::none() -> Healthcheck {
  {
    test_args: ["NONE"],
    interval_ms: None,
    timeout_ms: None,
    retries: None,
    start_period_ms: None,
    start_interval_ms: None,
  }
}

///|
/// Whether this healthcheck carries anything the daemon should see —
/// upstream's `to_docker_json` returns None for an all-default value.
fn Healthcheck::is_empty(self : Healthcheck) -> Bool {
  self.test_args.is_empty() &&
  self.interval_ms is None &&
  self.timeout_ms is None &&
  self.retries is None &&
  self.start_period_ms is None &&
  self.start_interval_ms is None
}

///|
pub fn Healthcheck::with_interval(
  self : Healthcheck,
  ms : Int32,
) -> Healthcheck {
  self.interval_ms = Some(ms)
  self
}

///|
pub fn Healthcheck::with_timeout(self : Healthcheck, ms : Int32) -> Healthcheck {
  self.timeout_ms = Some(ms)
  self
}

///|
pub fn Healthcheck::with_retries(self : Healthcheck, n : Int32) -> Healthcheck {
  self.retries = Some(n)
  self
}

///|
pub fn Healthcheck::with_start_period(
  self : Healthcheck,
  ms : Int32,
) -> Healthcheck {
  self.start_period_ms = Some(ms)
  self
}

///|
pub fn Healthcheck::with_start_interval(
  self : Healthcheck,
  ms : Int32,
) -> Healthcheck {
  self.start_interval_ms = Some(ms)
  self
}

///|
/// Attach a healthcheck to the image — serialized into
/// `Config.Healthcheck` at create time (direct adapter).
pub fn GenericImage::with_healthcheck(
  self : GenericImage,
  check : Healthcheck,
) -> GenericImage {
  self.healthcheck = Some(check)
  self
}

///|
/// Serialize to the create-JSON `Healthcheck` fragment (durations in
/// nanoseconds, upstream rule). Returns None for an empty healthcheck
/// so the caller can skip the key entirely (upstream `to_docker_json`
/// -> None).
fn Healthcheck::to_docker_json(self : Healthcheck) -> String? {
  if self.is_empty() {
    return None
  }
  let buf = StringBuilder()
  buf.write_char('{')
  let mut first = true
  fn emit(key : String, value : String) -> Unit {
    if !first {
      buf.write_char(',')
    }
    first = false
    buf.write_string(key)
    buf.write_char(':')
    buf.write_string(value)
  }
  if self.test_args.length() > 0 {
    emit("\"Test\"", json_array(self.test_args))
  }
  fn put_ms(key : String, ms : Int32?) -> Unit {
    match ms {
      Some(v) => emit(key, (v.to_int64() * 1000000L).to_string())
      None => ()
    }
  }
  put_ms("\"Interval\"", self.interval_ms)
  put_ms("\"Timeout\"", self.timeout_ms)
  put_ms("\"StartPeriod\"", self.start_period_ms)
  put_ms("\"StartInterval\"", self.start_interval_ms)
  match self.retries {
    Some(r) => emit("\"Retries\"", r.to_string())
    None => ()
  }
  buf.write_char('}')
  Some(buf.to_string())
}
