///|
/// Exec wait conditions (issue 0038), upstream `CmdWaitFor`. Message
/// conditions match against the fully captured stdout / stderr after
/// the exec completes — matching is post-completion substring on
/// buffered output, NOT streaming.
pub enum CmdWaitFor {
  Nothing
  StdOutMessage(String)
  StdErrMessage(String)
  Duration(Int32)
  Exit(Int32?)
}

///|
/// Run to completion with no additional condition.
pub fn CmdWaitFor::nothing() -> CmdWaitFor {
  Nothing
}

///|
/// Require `message` to appear in the captured stdout.
pub fn CmdWaitFor::stdout_message(message : String) -> CmdWaitFor {
  StdOutMessage(message)
}

///|
/// Require `message` to appear in the captured stderr.
pub fn CmdWaitFor::stderr_message(message : String) -> CmdWaitFor {
  StdErrMessage(message)
}

///|
/// After the exec completes, wait `milliseconds` more before
/// returning. Useful when the command's side effects settle
/// asynchronously. Always bounded by the exec timeout for the run
/// itself; the trailing sleep is unclamped but finite.
pub fn CmdWaitFor::duration(milliseconds : Int32) -> CmdWaitFor {
  Duration(milliseconds)
}

///|
/// Assert on the exit code: `None` accepts any completed exit,
/// `Some(code)` compares exactly. (Our exec always runs to completion,
/// so `None` adds no constraint beyond success.)
pub fn CmdWaitFor::exit(code : Int32?) -> CmdWaitFor {
  Exit(code)
}

///|
/// Evaluate a captured `ProcessOutput` against the condition.
/// Returns a diagnostic string on mismatch — message conditions
/// name the stream, exit conditions carry expected/actual.
fn cmd_wait_check(wait : CmdWaitFor, output : ProcessOutput) -> String? {
  match wait {
    Nothing | Duration(_) => None
    StdOutMessage(m) =>
      if output.stdout().contains(m) {
        None
      } else {
        Some("expected message not found on stdout")
      }
    StdErrMessage(m) =>
      if output.stderr().contains(m) {
        None
      } else {
        Some("expected message not found on stderr")
      }
    Exit(expected) =>
      match expected {
        None => None
        Some(code) =>
          if output.exit_code() == code {
            None
          } else {
            Some(
              "unexpected exec exit code: expected \{code}, got \{output.exit_code()}",
            )
          }
      }
  }
}

///|
/// `exec` with a post-completion wait condition (issue 0038). The
/// command always runs to completion under `timeout_ms` (default
/// 60 000); the condition is then applied to the captured output —
/// `StdOutMessage`/`StdErrMessage` substring checks, `Duration(ms)`
/// sleeps, `Exit(code)` compares the exit code. `ProcessOutput` always
/// carries a code (the direct path fails on undetermined codes), so a
/// missing-code false positive is impossible.
pub async fn Container::exec_wait(
  self : Container,
  command : Array[String],
  wait~ : CmdWaitFor = CmdWaitFor::nothing(),
  timeout_ms~ : Int32 = 60000,
) -> ProcessOutput {
  let output = if self.client is Some(client) {
    guard !self.removed else { fail("container already removed") }
    guard command.length() > 0 else { fail("exec command must not be empty") }
    let r = client.exec(
      self.id,
      cmd=command,
      deadline=Deadline::after(timeout_ms),
    )
    ProcessOutput::{
      exit_code: r.exit_code,
      stdout: @utf8.decode_lossy(r.stdout),
      stderr: @utf8.decode_lossy(r.stderr),
    }
  } else {
    guard !self.removed else { fail("container already removed") }
    guard command.length() > 0 else { fail("exec command must not be empty") }
    let result = @shell.Cmd(
      self.runtime.executable(),
      build_exec_args(self.id, command),
    ).output(timeout_ms~, max_output_bytes=67108864)
    ProcessOutput::{
      exit_code: result.exit_code(),
      stdout: result.stdout(),
      stderr: result.stderr(),
    }
  }
  match cmd_wait_check(wait, output) {
    Some(msg) => fail(msg)
    None =>
      match wait {
        Duration(ms) => {
          guard ms >= 0 else { fail("wait duration must not be negative") }
          @async.sleep(ms)
        }
        _ => ()
      }
  }
  output
}
