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

// M1 shared deadline/cancel rules (issue 0018). One absolute deadline is
// created at the `start` entry point and shared by every phase —
// connect, write, read, pull, create, start, readiness — so no phase
// can reset the timer. Cleanup work uses its own independent budget
// (same rule as 0001's `cleanup_budget_ms`).

///|
/// Absolute deadline on the `@async.now()` clock (milliseconds).
pub struct Deadline {
  at_ms : Int64
}

///|
/// A deadline `timeout_ms` from now.
pub fn Deadline::after(timeout_ms : Int32) -> Deadline {
  { at_ms: @async.now() + timeout_ms.to_int64(), }
}

///|
/// Wrap an absolute timestamp.
pub fn Deadline::at(at_ms : Int64) -> Deadline {
  { at_ms, }
}

///|
/// Milliseconds remaining; never negative.
pub fn Deadline::remaining_ms(self : Deadline) -> Int64 {
  let left = self.at_ms - @async.now()
  if left < 0L {
    0L
  } else {
    left
  }
}

///|
pub fn Deadline::expired(self : Deadline) -> Bool {
  self.remaining_ms() == 0L
}

///|
/// Run `op` under the remaining budget. Zero remaining time fails
/// immediately with `DeadlineExceeded`; expiry mid-flight raises the
/// same variant (distinct from `TransportError`).
pub async fn[X] Deadline::run(
  self : Deadline,
  op~ : String,
  task : async () -> X,
) -> X {
  let remaining = self.remaining_ms().to_int()
  if remaining <= 0 {
    raise EngineError::DeadlineExceeded(op~)
  }
  @async.with_timeout(remaining, task, error=EngineError::DeadlineExceeded(op~))
}

///|
/// Retry backoff for idempotent probes (e.g. exec inspect): upstream's
/// 10/50/200/500/1000 ms sequence, at most `ENGINE_RETRY_MAX` attempts,
/// each wait clamped to the remaining deadline.
let engine_retry_backoff_ms : Array[Int32] = [10, 50, 200, 500, 1000]

///|
pub const ENGINE_RETRY_MAX : Int32 = 6

///|
/// Sleep `ms` but never past the deadline; raises `DeadlineExceeded`
/// when no time remains.
pub async fn Deadline::sleep_bounded(
  self : Deadline,
  op~ : String,
  ms : Int32,
) -> Unit {
  let remaining = self.remaining_ms()
  if remaining <= 0L {
    raise EngineError::DeadlineExceeded(op~)
  }
  let capped = if ms.to_int64() < remaining { ms } else { remaining.to_int() }
  @async.sleep(capped)
}

///|
/// Backoff wait for attempt `i` (0-based), clamped to the deadline.
pub async fn Deadline::backoff(
  self : Deadline,
  op~ : String,
  attempt : Int32,
) -> Unit {
  let idx = if attempt < engine_retry_backoff_ms.length() {
    attempt
  } else {
    engine_retry_backoff_ms.length() - 1
  }
  self.sleep_bounded(op~, engine_retry_backoff_ms[idx])
}

///|
/// Independent short budget for cleanup work (rollback delete, log
/// unsubscribe). Shared with 0001's cleanup rule.
pub const CLEANUP_BUDGET_MS : Int32 = 5000
