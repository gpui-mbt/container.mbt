///|
/// Ownership label stamped on every container created by a `start` attempt.
/// The cleanup path removes a container only when its inspect output carries
/// this exact run identifier, so foreign containers are never deleted.
const OWNERSHIP_LABEL : String = "container-mbt.owned"

///|
/// A single `GenericImage::start` attempt: the effective container name plus
/// the run identifier that proves this attempt owns the created container.
pub struct RunAttempt {
  name : String
  run_id : String
  user_named : Bool
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
  match image.container_name {
    Some(name) => {
      guard valid_container_name(name) else {
        fail(
          "invalid container name: must be 2..63 ASCII characters and begin with an alphanumeric",
        )
      }
      { name, run_id, user_named: true, }
    }
    None => { name: "container-mbt-\{run_id}", run_id, user_named: false, }
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
