///|
/// Maximum bytes kept for a single log line before the prefix is
/// delivered as a truncated frame (upstream `MAX_LINE_LENGTH`, 8 MiB).
pub const LOG_LINE_MAX_BYTES = 8388608

///|
/// One delivered log line. `truncated` is true when the source line
/// exceeded `LOG_LINE_MAX_BYTES` — `data` then holds the leading
/// 8 MiB and the line's remainder was discarded (upstream line.rs).
pub struct LogFrame {
  /// "stdout" or "stderr" — multiplexed stream 1 / 2.
  stream : String
  data : Bytes
  truncated : Bool
}

///|
/// Per-stream line splitter (upstream `logs/line.rs`): split on `\n`,
/// strip a trailing `\r`, flush the pending tail on `finish`. A line
/// longer than `max` emits one `truncated` frame holding its first
/// `max` bytes; bytes up to the next newline are then discarded and a
/// single skip warning is recorded via `warned`.
priv struct LineSplitter {
  stream : String
  mut pending : Array[Byte]
  mut skipping : Bool
  limit : Int32
  sink : (LogFrame) -> Unit
}

///|
fn LineSplitter::new(
  stream : String,
  limit : Int32,
  sink : (LogFrame) -> Unit,
) -> LineSplitter {
  { stream, pending: [], skipping: false, limit, sink, }
}

///|
fn LineSplitter::emit(
  self : LineSplitter,
  end : Int32,
  truncated : Bool,
) -> Unit {
  // `end` is the index just past the last byte to keep, before the
  // `\n`; drop a `\r` immediately before it (upstream rule).
  let mut e = end
  if e > 0 && self.pending[e - 1] == b'\r' {
    e = e - 1
  }
  let data = Bytes::from_array(self.pending[0:e].to_owned())
  self.pending = self.pending[end + 1:].to_owned()
  (self.sink)({ stream: self.stream, data, truncated, })
}

///|
fn LineSplitter::feed(self : LineSplitter, bytes : Bytes) -> Unit {
  for b in bytes {
    if self.skipping {
      if b == b'\n' {
        self.skipping = false
      }
      continue
    }
    self.pending.push(b)
    if self.pending.length() > self.limit {
      // Over-long line: deliver the first `limit` bytes as truncated
      // and discard until the next newline (upstream behaviour).
      let data = Bytes::from_array(self.pending[0:self.limit].to_owned())
      self.pending.clear()
      self.skipping = true
      (self.sink)({ stream: self.stream, data, truncated: true, })
      continue
    }
    if b == b'\n' {
      self.emit(self.pending.length() - 1, false)
    }
  }
}

///|
/// EOF flush — a pending partial line is delivered whole (a skipping
/// tail was already dropped).
fn LineSplitter::finish(self : LineSplitter) -> Unit {
  if !self.skipping && self.pending.length() > 0 {
    let data = Bytes::from_array(self.pending)
    self.pending.clear()
    (self.sink)({ stream: self.stream, data, truncated: false, })
  }
}

///|
/// Byte-bounded drop-oldest frame queue shared by the pump and the
/// delivery task. A live stream can outpace a slow consumer; when the
/// retained bytes exceed `limit` the oldest frames are evicted and
/// `dropped_bytes`/`dropped_frames` grow — that is the observable skip
/// signal (upstream's reader-side skip warn).
priv struct FrameQueue {
  frames : Array[LogFrame]
  mut head : Int32
  mut bytes : Int64
  limit : Int64
  mut dropped_bytes : Int64
  mut dropped_frames : Int64
  mut closed : Bool
  cond : @cond_var.Cond
}

///|
fn FrameQueue::new(limit : Int64) -> FrameQueue {
  {
    frames: [],
    head: 0,
    bytes: 0L,
    limit,
    dropped_bytes: 0L,
    dropped_frames: 0L,
    closed: false,
    cond: @cond_var.Cond(),
  }
}

///|
/// Non-suspending push — safe to call from the `absorb` hook. Evicts
/// oldest frames until the new frame fits under the byte limit.
fn FrameQueue::put(self : FrameQueue, frame : LogFrame) -> Unit {
  if self.closed {
    return
  }
  self.frames.push(frame)
  self.bytes = self.bytes + frame.data.length().to_int64()
  while self.bytes > self.limit && self.head < self.frames.length() {
    let old = self.frames[self.head]
    self.head = self.head + 1
    self.bytes = self.bytes - old.data.length().to_int64()
    self.dropped_bytes = self.dropped_bytes + old.data.length().to_int64()
    self.dropped_frames = self.dropped_frames + 1L
  }
  self.cond.signal()
}

///|
/// Pop the next frame, suspending while the queue is empty. Returns
/// `None` once the queue is closed and drained.
async fn FrameQueue::get(self : FrameQueue) -> LogFrame? {
  while self.head >= self.frames.length() && !self.closed {
    self.cond.wait()
  }
  if self.head < self.frames.length() {
    let f = self.frames[self.head]
    self.head = self.head + 1
    self.bytes = self.bytes - f.data.length().to_int64()
    if self.head == self.frames.length() {
      self.frames.clear()
      self.head = 0
    }
    Some(f)
  } else {
    None
  }
}

///|
/// Stop accepting frames; a drained `get` returns `None` so the
/// delivery task exits after delivering what remains.
fn FrameQueue::close(self : FrameQueue) -> Unit {
  self.closed = true
  self.cond.broadcast()
}

///|
/// A live log subscription (upstream `LogConsumer` equivalent, 0040).
/// `Container::subscribe_logs` builds it; `run()` (spawned inside the
/// caller's task group) drives the `follow_logs` pump through
/// per-stream `LineSplitter`s into `queue` while a delivery task pops
/// frames into the consumer callback. `stop()` ends the stream and
/// waits for delivery to drain.
pub struct LogSubscription {
  priv session : DockerLogSession
  priv queue : FrameQueue
  priv client : DockerClient?
  priv consume : (LogFrame) -> Unit raise
  priv mut ended : Bool
  /// Consumer-callback failure that terminated delivery — `None` when
  /// only the pump ended (check `session.error()` via `error()`).
  priv mut failure : Error?
}

///|
/// Bytes of queued content evicted for a slow consumer — the
/// observable skip signal (upstream's reader-side warn-once).
pub fn LogSubscription::dropped_bytes(self : LogSubscription) -> Int64 {
  self.queue.dropped_bytes
}

///|
/// Count of evicted frames — non-zero means the consumer observed a
/// skip in the delivered sequence.
pub fn LogSubscription::dropped_frames(self : LogSubscription) -> Int64 {
  self.queue.dropped_frames
}

///|
/// The terminating error — a consumer-callback failure first, else
/// the pump's terminating error; `None` for a clean stop/EOF.
pub fn LogSubscription::error(self : LogSubscription) -> Error? {
  match self.failure {
    Some(e) => Some(e)
    None => self.session.error()
  }
}

///|
/// True once delivery has fully ended (queue drained or stopped).
pub fn LogSubscription::is_ended(self : LogSubscription) -> Bool {
  self.ended
}

///|
/// Subscriptions keyed by container id so `stop`/`rm` can halt
/// delivery before touching the runtime (upstream `stop_log_delivery`
/// ordering). Single-threaded async runtime — a plain Map suffices.
let active_log_subs : Map[String, Array[LogSubscription]] = Map([])

///|
/// Subscribe to live log frames from a running container (0040).
/// Direct-adapter only — CLI adapters fail explicitly. This is a
/// factory: spawn `sub.run()` inside the caller's task group to drive
/// the pump + delivery tasks, then `sub.stop()` ends it. `consume`
/// runs per delivered line; a callback exception ends the
/// subscription (recorded on `error()`) rather than leaking tasks.
pub fn Container::subscribe_logs(
  self : Container,
  consume : (LogFrame) -> Unit raise,
  buffer_limit~ : Int64 = 8388608L,
) -> LogSubscription raise {
  guard self.client is Some(_) else {
    fail("log subscription is not implemented by the CLI adapters")
  }
  guard !self.removed else { fail("container already removed") }
  let sub : LogSubscription = {
    session: DockerLogSession::new(
      id=self.id,
      buffer_limit=buffer_limit.to_int(),
    ),
    queue: FrameQueue::new(buffer_limit),
    client: self.client,
    consume,
    ended: false,
    failure: None,
  }
  match active_log_subs.get(self.id) {
    Some(list) => list.push(sub)
    None => active_log_subs[self.id] = [sub]
  }
  sub
}

///|
/// Drive the subscription (0040): runs the `follow_logs` pump and the
/// delivery task under one task group, returning once the stream ends
/// or `stop()` lands. Spawn it inside the caller's group —
/// `group.spawn_bg(() => sub.run())`.
pub async fn LogSubscription::run(self : LogSubscription) -> Unit {
  guard self.client is Some(client) else {
    fail("log subscription is not implemented by the CLI adapters")
  }
  @async.with_task_group(group => {
    let out_split = LineSplitter::new("stdout", LOG_LINE_MAX_BYTES, fn(f) {
      self.queue.put(f)
    })
    let err_split = LineSplitter::new("stderr", LOG_LINE_MAX_BYTES, fn(f) {
      self.queue.put(f)
    })
    self.session.on_frame = Some(fn(ty, payload) {
      if ty == 1 {
        out_split.feed(payload)
      } else if ty == 2 {
        err_split.feed(payload)
      }
    })
    // Pump: follow the stream, flush line tails, close the queue.
    group.spawn_bg(() => {
      client.follow_logs(self.session)
      out_split.finish()
      err_split.finish()
      self.queue.close()
    })
    // Delivery: drain the queue into the consumer. A callback failure
    // is recorded and ends delivery; cleanup is guaranteed.
    group.spawn_bg(() => {
      while true {
        match self.queue.get() {
          Some(frame) =>
            try (self.consume)(frame) catch {
              e => {
                self.failure = Some(e)
                self.session.stop()
                break
              }
            } noraise {
              _ => ()
            }
          None => break
        }
      }
      self.ended = true
    })
  })
}

///|
/// End the subscription: stop the stream (socket shutdown wakes the
/// pump), close the queue once the pump flushes, and wait for the
/// delivery task to finish. Bounded — returns even if tasks linger.
pub async fn LogSubscription::stop(self : LogSubscription) -> Unit {
  self.session.stop()
  self.queue.close()
  let deadline = @async.now() + 5000L
  while !self.ended && @async.now() < deadline {
    @async.sleep(10)
  }
}

///|
/// Stop every live subscription for `id` (called before runtime
/// stop/rm — upstream's stop_log_delivery-first ordering).
async fn stop_log_delivery(id : String) -> Unit {
  match active_log_subs.get(id) {
    Some(subs) => {
      for sub in subs {
        sub.session.stop()
        sub.queue.close()
      }
      let deadline = @async.now() + 5000L
      let mut pending = true
      while pending && @async.now() < deadline {
        pending = subs.iter().any(fn(s) { !s.ended })
        if pending {
          @async.sleep(10)
        }
      }
      active_log_subs.remove(id)
    }
    None => ()
  }
}
