// Copyright 2026 gpui-mbt contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

///|
test "deadline remaining time shrinks, never negative" {
  let d = Deadline::after(60_000)
  assert_true(d.remaining_ms() > 59_000L)
  assert_true(!d.expired())
  let past = Deadline::at(@async.now() - 1000L)
  assert_true(past.expired())
  assert_eq(past.remaining_ms(), 0L)
}

///|
async test "run raises DeadlineExceeded immediately when expired" {
  let past = Deadline::at(@async.now() - 1000L)
  let start = @async.now()
  try past.run(op="probe", () => ()) catch {
    EngineError::DeadlineExceeded(op="probe") => ()
    err => fail("expected DeadlineExceeded, got \{err}")
  } noraise {
    _ => fail("expected DeadlineExceeded")
  }
  assert_true(@async.now() - start < 500L)
}

///|
async test "run interrupts a stalled read at the deadline" {
  let d = Deadline::after(80)
  let start = @async.now()
  try d.run(op="read", () => @async.sleep(10_000)) catch {
    EngineError::DeadlineExceeded(op="read") => ()
    err => fail("expected DeadlineExceeded, got \{err}")
  } noraise {
    _ => fail("expected DeadlineExceeded")
  }
  let elapsed = @async.now() - start
  assert_true(elapsed >= 80L && elapsed < 2000L)
}

///|
/// The backoff wait is clamped to the remaining deadline — sleeping the
/// full table value would overshoot.
async test "retry backoff is clamped to the deadline" {
  let d = Deadline::after(60)
  let start = @async.now()
  // attempt 4 would sleep 1000ms without clamping
  d.backoff(op="probe", 4)
  assert_true(@async.now() - start < 200L)
  // now expired: next backoff raises instead of sleeping
  try d.backoff(op="probe", 0) catch {
    EngineError::DeadlineExceeded(_) => ()
    err => fail("expected DeadlineExceeded, got \{err}")
  } noraise {
    _ => fail("expected DeadlineExceeded after deadline")
  }
}

///|
/// Fake daemon that accepts but never responds — the read must abort at
/// the shared deadline, bounded by deadline + nothing else.
async test "request aborts at the shared deadline when the daemon stalls" {
  let dir = @fs.tmpdir(prefix="container-mbt-deadline")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  let deadline = Deadline::after(300)
  let start = @async.now()
  let mut elapsed : Int64 = -1L
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      // accept and stall forever — simulates a hung daemon
      let mut fd : Int32? = None
      for i = 0; i < 10_000 && fd is None; i = i + 1 {
        fd = unix_accept(listen_fd)
        if fd is None {
          @async.sleep(1)
        }
      }
      let conn = unix_socket_from_fd(fd.unwrap())
      defer conn.close()
      // outlive the 300ms client deadline, but keep the test fast
      @async.sleep(800)
    })
    let client = DockerClient::new(socket_path=sock)
    try client.ping(deadline~) catch {
      EngineError::DeadlineExceeded(op="ping") => {
        elapsed = @async.now() - start
        ()
      }
      err => fail("expected DeadlineExceeded, got \{err}")
    } noraise {
      _ => fail("expected DeadlineExceeded")
    }
  })
  assert_true(elapsed >= 300L && elapsed < 2000L)
}
