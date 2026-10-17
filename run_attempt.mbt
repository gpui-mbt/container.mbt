///|
/// Ownership label stamped on every container created by a `start` attempt.
/// The cleanup path removes a container only when its inspect output carries
/// this exact run identifier, so foreign containers are never deleted.
const OWNERSHIP_LABEL : String = "container-mbt.owned"

///|
/// Process-wide owner identity (0021): `p<pid>t<hex>` — pid plus an
/// unpredictable stamp, matching upstream's unique_suffix idea. The
/// `container-mbt.owned` label stores THIS value so a later process can
/// attribute orphaned containers to a dead owner.
let owner_state : Ref[(String, Int32)?] = { val: None, }

///|
/// Extra entropy so two racing `ensure_owner_lock` calls in one process
/// never generate the same owner id (same pid + same millisecond is
/// possible; the nonce cannot repeat).
let owner_nonce : Ref[UInt64] = { val: 0, }

///|
fn generate_owner_id() -> String {
  owner_nonce.val += 1
  let pid = process_pid()
  let stamp = mix64(
    @async.now().reinterpret_as_uint64() +
    (pid.to_uint64() << 32) +
    (owner_nonce.val << 17),
  )
  "p\{pid}-t\{u64_hex(stamp)}"
}

///|
/// This process's owner id, or `None` when the owner lock has not been
/// acquired yet (no container may be labeled before then).
fn current_owner_id() -> String? {
  match owner_state.val {
    Some((id, _)) => Some(id)
    None => None
  }
}

///|
/// Owner lock directory: `$XDG_RUNTIME_DIR/container-mbt`, falling back
/// to `/tmp/container-mbt-<uid>` — always a private 0700 directory.
fn owner_lock_dir() -> String {
  match @env.get_env_var("XDG_RUNTIME_DIR") {
    Some(dir) if dir != "" => "\{dir}/container-mbt"
    _ => "/tmp/container-mbt-\{process_uid()}"
  }
}

///|
fn owner_lock_path(dir : String, owner_id : String) -> String {
  "\{dir}/owner-\{owner_id}.lock"
}

///|
/// Acquire this process's owner lock once; the fd is held for the
/// process lifetime so the kernel releases it on any death — SIGKILL
/// included — letting a later run prove the owner is gone.
pub async fn ensure_owner_lock() -> String {
  match owner_state.val {
    Some((id, _)) => id
    None => {
      let dir = owner_lock_dir()
      @fs.mkdir(dir, permission=0o700, recursive=true, allow_exist=true)
      let owner_id = generate_owner_id()
      match try_owner_lock(owner_lock_path(dir, owner_id)) {
        Some(fd) => {
          owner_state.val = Some((owner_id, fd))
          owner_id
        }
        None => fail("owner lock held by another process: \{owner_id}")
      }
    }
  }
}

///|
/// Probe another owner's liveness: acquiring its lock means the owning
/// process is dead. Sync syscall only; callers provide the lock dir so
/// probing is a pure function of the label value.
fn owner_alive(dir : String, owner_id : String) -> Bool raise {
  match try_owner_lock(owner_lock_path(dir, owner_id)) {
    Some(fd) => {
      release_lock(fd)
      false
    }
    None => true
  }
}

///|
/// `p<digits>-t<16 lowercase hex>` — rejects malformed label values so
/// recovery never guesses at a lock path from arbitrary input.
fn valid_owner_id(id : String) -> Bool {
  let view = id[:]
  guard view.has_prefix("p") else { return false }
  let parts = view[1:].split("-t").to_array()
  guard parts.length() == 2 else { return false }
  guard parts[0].length() > 0 &&
    parts[0].iter().all(fn(c) { c is ('0'..<='9') }) else {
    return false
  }
  guard parts[1].length() == 16 &&
    parts[1].iter().all(fn(c) { c is ('0'..<='9' | 'a'..<='f') }) else {
    return false
  }
  true
}

///|
/// A single `GenericImage::start` attempt: the effective container name plus
/// the run identifier that proves this attempt owns the created container.
pub struct RunAttempt {
  name : String
  run_id : String
  user_named : Bool
  /// Process owner id — stored in the `container-mbt.owned` label (0021).
  owner_id : String
}

///|
pub fn RunAttempt::name(self : RunAttempt) -> String {
  self.name
}

///|
pub fn RunAttempt::run_id(self : RunAttempt) -> String {
  self.run_id
}

///|
/// The process owner id stamped into the `container-mbt.owned` label.
pub fn RunAttempt::owner_id(self : RunAttempt) -> String {
  self.owner_id
}

///|
/// Whether the name came from `with_container_name` instead of generation.
pub fn RunAttempt::user_named(self : RunAttempt) -> Bool {
  self.user_named
}

///|
/// Prepare the identity of one `start` attempt. When the caller did not name
/// the container, a `container-mbt-<run id>` name is generated so a failed
/// run can be found and collected by name afterwards.
pub fn RunAttempt::prepare(image : GenericImage) -> RunAttempt raise {
  let run_id = next_run_id()
  // No owner lock, no labeled container — otherwise a live process's
  // leavings could look orphaned to a later recovery run.
  let owner_id = match current_owner_id() {
    Some(id) => id
    None => fail("owner lock not held; ensure_owner_lock must run first")
  }
  match image.container_name {
    Some(name) => {
      guard valid_container_name(name) else {
        fail(
          "invalid container name: must be 2..63 ASCII characters and begin with an alphanumeric",
        )
      }
      { name, run_id, user_named: true, owner_id, }
    }
    None =>
      { name: "container-mbt-\{run_id}", run_id, user_named: false, owner_id, }
  }
}

///|
/// Count of run attempts made by this process; feeds the run identifier.
let run_sequence : Ref[UInt64] = { val: 0, }

///|
/// Process-wide salt mixed into every run identifier so two processes that
/// start in the same millisecond do not produce the same identifier stream.
let run_epoch : UInt64 = mix64(@async.now().reinterpret_as_uint64())

///|
/// A unique, hard-to-predict identifier for one `start` attempt. Not a
/// secret: it only has to distinguish this attempt from every other
/// container, including containers created by other processes.
fn next_run_id() -> String {
  run_sequence.val += 1
  let stamp = @async.now().reinterpret_as_uint64()
  let mixed = mix64(run_epoch + stamp + (run_sequence.val << 17))
  "\{u64_hex(stamp)}\{u64_hex(mixed)}"
}

///|
/// SplitMix64-style finalizer: diffuses the time/counter input enough that
/// generated names cannot be predicted from a nearby clock reading.
fn mix64(value : UInt64) -> UInt64 {
  let z = value + 0x9E3779B97F4A7C15UL
  let z = z.lxor(z >> 30) * 0xBF58476D1CE4E5B9UL
  let z = z.lxor(z >> 27) * 0x94D049BB133111EBUL
  z.lxor(z >> 31)
}

///|
fn u64_hex(value : UInt64) -> String {
  let digits = "0123456789abcdef"
  let buf = StringBuilder()
  for i in 0..<16 {
    let shift = 60 - i * 4
    let nibble = ((value >> shift) & 0xFUL).to_int()
    match digits.get_char(nibble) {
      Some(c) => buf.write_char(c)
      None => ()
    }
  }
  buf.to_string()
}
