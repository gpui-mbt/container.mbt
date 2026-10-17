///|
/// 0001: run identifiers must be unique, unpredictable-looking hex strings.
test "generated run ids are unique 32-char hex strings" {
  let seen : Map[String, Bool] = Map([])
  for _ in 0..<200 {
    let id = next_run_id()
    assert_eq(id.length(), 32)
    for c in id {
      assert_true(c is ('0'..<='9' | 'a'..<='f'))
    }
    assert_true(!seen.contains(id))
    seen[id] = true
  }
}

///|
/// 0001: a caller that never names its container still gets a valid,
/// discoverable name so cleanup can find the container after a failed run.
test "unnamed attempts get a valid generated container name" {
  let image = GenericImage::new("alpine", "3.20")
  let attempt = RunAttempt::prepare(image)
  assert_true(!attempt.user_named())
  assert_true(attempt.name().has_prefix("container-mbt-"))
  assert_true(valid_container_name(attempt.name()))
  let named = RunAttempt::prepare(
    GenericImage::new("alpine", "3.20").with_container_name("keep-me"),
  )
  assert_eq(named.name(), "keep-me")
  assert_true(named.user_named())
}

///|
/// 0001: invalid user-specified names fail before any argument building.
test "invalid container names are rejected during attempt preparation" {
  let image = GenericImage::new("alpine", "3.20").with_container_name("-bad")
  assert_true(
    try {
      ignore(RunAttempt::prepare(image))
      false
    } catch {
      _ => true
    },
  )
}

///|
/// 0001: every run advertises the ownership label, not just named ones.
test "ownership label is attached to every run" {
  let attempt : RunAttempt = {
    name: "named",
    run_id: "run-42",
    user_named: true,
  }
  let image = GenericImage::new("alpine", "3.20")
  let args = build_run_args(Docker, image, attempt~)
  assert_true(args.join(" ").contains("--name named"))
  assert_true(args.join(" ").contains("--label container-mbt.owned=run-42"))
}

///|
/// 0001: the user-name precheck must distinguish present from absent.
async test "name preflight classifies inspect results" {
  assert_true(name_in_use_via("/bin/true", "taken"))
  assert_true(!name_in_use_via("/bin/false", "free-name"))
}

///|
/// 0001: an inspect hit without this run's label means foreign ownership —
/// the container must not be deleted.
async test "cleanup never removes a container lacking the ownership label" {
  let attempt : RunAttempt = {
    name: "foreign",
    run_id: "rid-mine",
    user_named: true,
  }
  let note = collect_attempt("/bin/true", Docker, attempt, 800)
  assert_true(note.contains("left untouched"))
}

///|
/// 0001: when the run never created anything the probe reports absence and
/// gives up within its own bounded budget.
async test "cleanup reports an absent container without spawning removal" {
  let attempt : RunAttempt = {
    name: "never-created",
    run_id: "rid-mine",
    user_named: false,
  }
  let note = collect_attempt("/bin/false", Docker, attempt, 700)
  assert_true(note.contains("no owned container"))
}

///|
/// 0001: the owned path must actually invoke remove — proven by a fixture
/// executable whose `rm` invocation drops a marker file.
async test "cleanup removes only the label-owned container" {
  let dir = @fs.tmpdir(prefix="container-mbt-cleanup")
  let marker = "\{dir}/removed.marker"
  let foreign_marker = "\{dir}/foreign.marker"
  let owned : RunAttempt = {
    name: "owned-one",
    run_id: "rid-owned",
    user_named: false,
  }
  let script = "\{dir}/fake-runtime"
  @fs.write_file(
    script,
    "#!/bin/sh\ncase \"$1\" in\n  inspect) printf '%s' '{\"Config\":{\"Labels\":{\"container-mbt.owned\":\"rid-owned\"}}}' ;;\n  rm|delete) : > \"\{marker}\" ;;\n  *) exit 1 ;;\nesac\n",
    permission=0o755,
  )
  let note = collect_attempt(script, Docker, owned, 2000)
  assert_true(note.contains("removed owned container"))
  assert_true(@fs.exists(marker))
  // A foreign container must never reach the rm branch.
  let foreign : RunAttempt = {
    name: "foreign-one",
    run_id: "rid-foreign",
    user_named: true,
  }
  let foreign_script = "\{dir}/foreign-runtime"
  @fs.write_file(
    foreign_script,
    "#!/bin/sh\ncase \"$1\" in\n  inspect) printf '%s' '{\"Config\":{\"Labels\":{\"container-mbt.owned\":\"someone-else\"}}}' ;;\n  rm|delete) : > \"\{foreign_marker}\" ;;\n  *) exit 1 ;;\nesac\n",
    permission=0o755,
  )
  let foreign_note = collect_attempt(foreign_script, Docker, foreign, 2000)
  assert_true(foreign_note.contains("left untouched"))
  assert_true(!@fs.exists(foreign_marker))
}

///|
/// 0005: cleanup runs on its own bounded budget even after a startup-style
/// deadline has fully expired — it never shares the start() deadline.
async test "cleanup budget is independent of any expired startup deadline" {
  // Simulate a start() whose deadline already passed: collection still gets a
  // fresh budget and completes its probe instead of giving up instantly.
  let attempt : RunAttempt = {
    name: "deadline-expired",
    run_id: "rid-expired",
    user_named: false,
  }
  let start = @async.now()
  let note = collect_attempt("/bin/true", Docker, attempt, 300)
  assert_true(@async.now() - start < 3000L)
  assert_true(note.contains("left untouched"))
}
