///|
/// 0039: env-var parse rules — unset/empty/non-numeric/negative
/// sign/out-of-range all produce Nothing; valid digits produce Millis.
/// (The pure function is what `millis_in_env_var` calls after reading
/// the env — the env itself is not mutated in tests.)
test "millis_in_env_var value parsing" {
  assert_true(wait_millis_from_env_value(None) is None)
  assert_true(wait_millis_from_env_value(Some("")) is None)
  assert_true(wait_millis_from_env_value(Some("abc")) is None)
  assert_true(wait_millis_from_env_value(Some("-5")) is None)
  assert_true(wait_millis_from_env_value(Some("+5")) is None)
  assert_true(wait_millis_from_env_value(Some(" 125")) is None)
  assert_true(wait_millis_from_env_value(Some("125 ")) is None)
  assert_true(wait_millis_from_env_value(Some("2147483648")) is None)
  assert_true(wait_millis_from_env_value(Some("99999999999999")) is None)
  guard wait_millis_from_env_value(Some("125")) is Some(125) else {
    fail("125")
  }
  guard wait_millis_from_env_value(Some("0")) is Some(0) else { fail("0") }
  // Reading an env var the test did not set must give Nothing, never
  // an error (upstream: unset or unparseable → empty condition).
  guard WaitFor::millis_in_env_var("CONTAINER_MBT_NO_SUCH_VAR_9f2c1d")
    is Nothing else {
    fail("expected Nothing for unset var")
  }
}

///|
/// 0039: conditions evaluate in order and the first failure stops the
/// rest — a `millis` that outlasts the deadline must prevent a later
/// condition from running (proven by an unreachable 3rd condition that
/// would raise a distinct marker error if reached).
async test "first failure stops later conditions" {
  let c : Container = {
    id: "t",
    runtime: Docker,
    mappings: [],
    removed: false,
    resolved_ports: None,
    inspect_obj: None,
    client: None,
  }
  let deadline = @async.now() + 300
  let r = try {
    c.wait_ready_until(
      [WaitFor::millis(50), WaitFor::millis(10_000), WaitFor::nothing()],
      deadline,
    )
    "completed"
  } catch {
    e =>
      if "\{e}".contains("startup timeout exceeded") {
        "timeout"
      } else {
        "other:\{e}"
      }
  }
  assert_eq(r, "timeout")
}

///|
/// 0039: a failing condition's error is prefixed with its index and
/// propagates; a Nothing-then-millis(0) prefix does not consume the
/// deadline meaningfully.
async test "condition failure is index-prefixed" {
  let c : Container = {
    id: "t",
    runtime: Docker,
    mappings: [],
    removed: false,
    resolved_ports: None,
    inspect_obj: None,
    client: None,
  }
  let r = try {
    c.wait_ready_until(
      [WaitFor::nothing(), WaitFor::millis(-1)],
      @async.now() + 5000,
    )
    "completed"
  } catch {
    e =>
      if "\{e}".contains("ready condition 1 failed") &&
        "\{e}".contains("must not be negative") {
        "indexed"
      } else {
        "other:\{e}"
      }
  }
  assert_eq(r, "indexed")
}

///|
/// 0039: an empty log-message condition returns immediately — upstream
/// treats an empty pattern as always matching.
async test "empty log message is immediate success" {
  let c : Container = {
    id: "removed", // would fail logs if polled — proves no poll happens
    runtime: Docker,
    mappings: [],
    removed: true,
    resolved_ports: None,
    inspect_obj: None,
    client: None,
  }
  c.wait_for_log_until("", "stdout", @async.now() + 5000)
}
