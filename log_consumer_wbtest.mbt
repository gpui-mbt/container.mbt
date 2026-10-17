///|
/// 0040: line splitting — `\n` boundaries, `\r` strip, multi-chunk
/// joins, EOF flush of a trailing partial line.
test "line splitter splits on newlines and strips CR" {
  let got : Array[String] = []
  let sp = LineSplitter::new("stdout", 16, fn(f) {
    got.push(
      "\{f.data |> @utf8.decode_lossy}\{if f.truncated { "!" } else { "" }}",
    )
  })
  // split across chunk boundaries
  sp.feed(b"hel")
  assert_eq(got, [])
  sp.feed(b"lo\nwor")
  sp.feed(b"ld\r\nx\n")
  sp.finish()
  assert_eq(got, ["hello", "world", "x"])
}

///|
/// 0040: an over-limit line delivers one truncated frame holding the
/// first `limit` bytes; the rest of the line is discarded and the
/// next line still arrives.
test "over-limit line truncates then recovers" {
  let got : Array[(Int32, Bool)] = []
  let sp = LineSplitter::new("stdout", 8, fn(f) {
    got.push((f.data.length(), f.truncated))
  })
  // 20-byte line: 8 emitted truncated, remaining 12 + \n discarded
  sp.feed(b"01234567890123456789\n")
  sp.feed(b"ok\n")
  sp.finish()
  assert_eq(got, [(8, true), (2, false)])
}

///|
/// 0040: byte-bounded drop-oldest — a slow reader sees the newest
/// frames while `dropped_*` count the skipped prefix.
test "frame queue drops oldest under byte pressure" {
  let q = FrameQueue::new(24)
  let f = fn(n : Int32) {
    LogFrame::{
      stream: "stdout",
      data: Bytes::make(n, b'x'),
      truncated: false,
    }
  }
  q.put(f(8))
  q.put(f(8))
  q.put(f(8)) // exactly full
  assert_eq(q.dropped_frames, 0L)
  q.put(f(8)) // one over → oldest evicted
  assert_eq(q.dropped_frames, 1L)
  assert_eq(q.dropped_bytes, 8L)
  q.close()
}

///|
/// 0040: a draining reader gets surviving frames in order and `None`
/// after close; a closing-before-read queue still delivers buffered
/// frames first.
async test "frame queue drain order and close" {
  let q = FrameQueue::new(1024)
  let f = fn(n : Byte) {
    LogFrame::{ stream: "stdout", data: Bytes::make(4, n), truncated: false, }
  }
  q.put(f(b'a'))
  q.put(f(b'b'))
  q.close()
  let r1 = q.get()
  let r2 = q.get()
  let r3 = q.get()
  assert_eq(r1.unwrap().data[0], b'a')
  assert_eq(r2.unwrap().data[0], b'b')
  assert_true(r3 is None)
}

///|
/// Mock-engine subscription fixture: `frames` is the raw multiplexed
/// body the daemon serves on the follow request.
fn sub_fixture(frames : Bytes) -> Bytes {
  http_stream_resp("application/vnd.docker.multiplexed-stream", frames)
}

///|
/// 0040: end-to-end — multiplexed stdout/stderr frames arrive as
/// ordered lines, streams stay separated, and `stop()` ends delivery.
async test "subscription delivers ordered separated lines" {
  let dir = @fs.tmpdir(prefix="container-mbt-sub")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let requests : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        1,
        fn(_head) {
          sub_fixture(
            exec_frame(1, b"out-1\nout-2\n") +
            exec_frame(2, b"err-1\n") +
            exec_frame(1, b"out-3\n"),
          )
        },
        requests,
      )
    })
    let c : Container = {
      id: "sub1",
      runtime: Docker,
      mappings: [],
      removed: false,
      resolved_ports: None,
      inspect_obj: None,
      client: Some(DockerClient::new(socket_path=sock)),
    }
    let got : Array[String] = []
    let sub = c.subscribe_logs(fn(f) {
      got.push("\{f.stream}:\{f.data |> @utf8.decode_lossy}")
    })
    group.spawn_bg(() => sub.run())
    // wait for delivery to drain
    let deadline = @async.now() + 5000L
    while !sub.is_ended() && @async.now() < deadline {
      @async.sleep(10)
    }
    assert_eq(got, [
      "stdout:out-1", "stdout:out-2", "stderr:err-1", "stdout:out-3",
    ])
    assert_eq(sub.dropped_frames(), 0L)
    assert_true(sub.error() is None)
  })
}

///|
/// 0040: a consumer-callback exception ends delivery without leaking
/// tasks and surfaces via `error()`.
async test "consumer exception ends subscription cleanly" {
  let dir = @fs.tmpdir(prefix="container-mbt-subx")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let requests : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        1,
        fn(_head) { sub_fixture(exec_frame(1, b"boom\nmore\n")) },
        requests,
      )
    })
    let c : Container = {
      id: "sub2",
      runtime: Docker,
      mappings: [],
      removed: false,
      resolved_ports: None,
      inspect_obj: None,
      client: Some(DockerClient::new(socket_path=sock)),
    }
    let sub = c.subscribe_logs(fn(_f) raise { fail("consumer boom") })
    group.spawn_bg(() => sub.run())
    let deadline = @async.now() + 5000L
    while !sub.is_ended() && @async.now() < deadline {
      @async.sleep(10)
    }
    assert_true(sub.is_ended())
    match sub.error() {
      Some(e) => assert_true("\{e}".contains("consumer boom"))
      None => fail("expected consumer error")
    }
  })
}

///|
/// 0040: CLI containers refuse subscription before any process spawn.
test "cli container refuses subscribe_logs" {
  let bare : Container = {
    id: "t",
    runtime: Docker,
    mappings: [],
    removed: false,
    resolved_ports: None,
    inspect_obj: None,
    client: None,
  }
  let r = try {
    ignore(bare.subscribe_logs(fn(_f) { () }))
    "subscribed"
  } catch {
    e =>
      if "\{e}".contains("CLI adapters") {
        "cli-refusal"
      } else {
        "other:\{e}"
      }
  }
  assert_eq(r, "cli-refusal")
}
