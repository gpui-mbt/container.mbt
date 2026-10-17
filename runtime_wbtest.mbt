///|
/// What: a condition longer than the allotted time must be interrupted.
async test "single readiness delay cannot exceed startup deadline" {
  let container : Container = {
    id: "unstarted-test",
    runtime: Docker,
    mappings: [],
    removed: false,
    resolved_ports: None,
    inspect_obj: None,
  }
  let start = @async.now()
  let timed_out = try {
    container.wait_ready([WaitFor::millis(1000)], 100)
    false
  } catch {
    _ => true
  }
  assert_true(timed_out)
  assert_true(@async.now() - start < 550L)
}

///|
/// What: successive waits share one deadline instead of each resetting it.
async test "multiple delays respect one readiness budget" {
  let container : Container = {
    id: "unstarted-test",
    runtime: Docker,
    mappings: [],
    removed: false,
    resolved_ports: None,
    inspect_obj: None,
  }
  let start = @async.now()
  let timed_out = try {
    container.wait_ready([WaitFor::millis(180), WaitFor::millis(600)], 260)
    false
  } catch {
    _ => true
  }
  assert_true(timed_out)
  assert_true(@async.now() - start < 700L)
}

///|
/// What: a deadline begun before waiting cannot be reset by readiness logic.
async test "readiness receives the remaining run-start time" {
  let container : Container = {
    id: "unstarted-test",
    runtime: Docker,
    mappings: [],
    removed: false,
    resolved_ports: None,
    inspect_obj: None,
  }
  let deadline = @async.now() + 240L
  @async.sleep(150)
  let phase_started = @async.now()
  let timed_out = try {
    container.wait_ready_until([WaitFor::millis(200)], deadline)
    false
  } catch {
    _ => true
  }
  assert_true(timed_out)
  assert_true(@async.now() - phase_started < 190L)
}

///|
/// What: subprocess timeouts are no longer granted more than remaining time.
test "log polling budget is clamped by startup deadline" {
  let deadline = @async.now() + 200L
  assert_true(startup_command_timeout_ms(deadline, 15000) <= 200)
  assert_true(startup_command_timeout_ms(deadline, 250) <= 200)
  assert_true(
    try {
      ignore(startup_remaining_ms(@async.now() - 1L))
      false
    } catch {
      _ => true
    },
  )
}

///|
/// What: the builder's exported mappings array cannot mutate the original.
test "port mapping accessors return detached snapshots" {
  let image = GenericImage::new("alpine", "3.20").with_mapped_port(
    18080,
    ContainerPort::tcp(80),
  )
  let detached = image.mappings()
  detached.push(PortMapping::new(18081, ContainerPort::tcp(81)))
  assert_eq(image.mappings().length(), 1)
}
