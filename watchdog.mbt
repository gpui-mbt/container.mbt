///|
/// `TESTCONTAINERS_COMMAND=keep` — exact match only (upstream rule):
/// no case-folding, no trim, no substring. Gates automatic cleanup
/// (scope exit + watchdog); explicit `rm()` is never gated.
fn keep_containers() -> Bool {
  @env.get_env_var("TESTCONTAINERS_COMMAND") == Some("keep")
}

///|
/// Upstream `watchdog.rs` spawn-failure bound — a disabled watchdog
/// never respawns, and the transition is recorded once.
const WATCHDOG_MAX_SPAWN_FAILURES = 3

///|
/// The reaper process contract (upstream `watchdog.rs`): a `/bin/sh`
/// orphan whose stdin is a pipe we hold open. Parent death — any
/// signal — closes our end, the reaper's `read` hits EOF, and it
/// force-removes every registered id, but only after re-verifying
/// the `container-mbt.owned` label via inspect so an id can never
/// point at a foreign or user-owned container.
priv struct Reaper {
  pipe : @process.WriteToProcess
}

///|
priv struct WatchdogState {
  mut reaper : Reaper?
  mut spawn_failures : Int32
  mut disabled : Bool
  /// One-time observable warnings — the port of upstream's `warn!`.
  warnings : Array[String]
}

///|
let watchdog_state : WatchdogState = {
  reaper: None,
  spawn_failures: 0,
  disabled: false,
  warnings: [],
}

///|
/// A line-framed registration channel cannot carry ids that break
/// the framing (upstream rejects ids containing control chars).
fn registrable_id(id : String) -> Bool {
  guard id.length() > 0 else { return false }
  for c in id {
    guard c != '\n' && c != '\r' && c != ' ' && c != '\t' else { return false }
  }
  true
}

///|
/// Spawn the reaper once per process (upstream: 1 process, 1 reaper).
/// The reaper re-checks the ownership label at reap time; `docker`
/// CLI absence is a spawn-time-or-reap-time failure that only
/// disables the watchdog after WATCHDOG_MAX_SPAWN_FAILURES attempts.
async fn spawn_reaper() -> Reaper {
  spawn_reaper_with(REAPER_SCRIPT)
}

///|
/// The reaper's shell program — factored out so tests can prove the
/// EOF contract with a marker-file script instead of `docker rm`.
/// Accumulate ids until stdin EOFs (parent death — any signal —
/// closes our write end), then reap, but only ids still carrying the
/// `container-mbt.owned` label at reap time so a recycled id can
/// never point at a foreign container.
const REAPER_SCRIPT : String = "ids=''; while IFS= read -r id; do ids=\"$ids $id\"; done; " +
  "for id in $ids; do " +
  "if docker inspect --format '{{index .Config.Labels \"container-mbt.owned\"}}' \"$id\" 2>/dev/null | grep -q .; then " +
  "docker rm -f \"$id\" >/dev/null 2>&1 || :; fi; done"

///|
async fn spawn_reaper_with(script : String) -> Reaper {
  let (stdin_src, write_end) = @process.write_to_process()
  ignore(@process.spawn_orphan("/bin/sh", ["-c", script], stdin=stdin_src))
  { pipe: write_end, }
}

///|
/// Register a container id with the reaper (0042). No-op under
/// `TESTCONTAINERS_COMMAND=keep`, for unregistrable ids, for
/// non-Docker runtimes (the script needs the `docker` CLI binary —
/// direct-API crash recovery is 0021's owner-lock sweep instead),
/// and once the watchdog is disabled. A dead reaper (write failure)
/// respawns within the spawn-failure bound.
async fn watchdog_register(runtime : Runtime, id : String) -> Unit {
  if keep_containers() ||
    watchdog_state.disabled ||
    !registrable_id(id) ||
    !(runtime is Docker) {
    return
  }
  // (Re)spawn once when no live reaper is known — spawn failures
  // count against the bound; writes to a dead reaper surface as
  // write errors and also count.
  let mut tried = false
  while watchdog_state.reaper is None && !tried {
    tried = true
    try {
      watchdog_state.reaper = Some(spawn_reaper())
    } catch {
      _ => {
        watchdog_state.spawn_failures = watchdog_state.spawn_failures + 1
        if watchdog_state.spawn_failures >= WATCHDOG_MAX_SPAWN_FAILURES {
          watchdog_state.disabled = true
          watchdog_state.warnings.push(
            "container watchdog disabled after \{WATCHDOG_MAX_SPAWN_FAILURES} spawn failures",
          )
        }
        return
      }
    } noraise {
      _ => ()
    }
  }
  guard watchdog_state.reaper is Some(reaper) else { return }
  try reaper.pipe.write(@utf8.encode("\{id}\n")) catch {
    _ => {
      // Reaper died (external kill) — forget it so the next
      // registration respawns, still bounded by MAX_SPAWN_FAILURES.
      watchdog_state.reaper = None
      watchdog_state.spawn_failures = watchdog_state.spawn_failures + 1
      if watchdog_state.spawn_failures >= WATCHDOG_MAX_SPAWN_FAILURES {
        watchdog_state.disabled = true
        watchdog_state.warnings.push(
          "container watchdog disabled after \{WATCHDOG_MAX_SPAWN_FAILURES} spawn failures",
        )
      }
    }
  } noraise {
    _ => ()
  }
}
