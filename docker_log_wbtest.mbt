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
test "log buffer drops oldest bytes past the limit" {
  let buf = LogBuffer::new(6)
  buf.push(b"abcd")
  buf.push(b"efgh")
  // 8 bytes written into a 6-byte window: "ab" is evicted.
  assert_eq(@utf8.decode_lossy(Bytes::from_array(buf.data)), "cdefgh")
  assert_eq(buf.dropped, 2L)
  // Exactly-at-limit stays.
  let exact = LogBuffer::new(4)
  exact.push(b"1234")
  assert_eq(@utf8.decode_lossy(Bytes::from_array(exact.data)), "1234")
  assert_eq(exact.dropped, 0L)
}

///|
test "frame sink reassembles headers split across feeds" {
  let sink = FrameSink::new()
  let frame = exec_frame(1, b"hello") + exec_frame(2, b"oops")
  // Feed one byte at a time — worst-case receive splitting.
  let delivered : Array[(Int32, Bytes)] = []
  for b in frame {
    let got = sink.feed(Bytes::from_array([b]))
    for f in got {
      delivered.push(f)
    }
  }
  assert_eq(delivered.length(), 2)
  assert_eq(delivered[0].0, 1)
  assert_eq(@utf8.decode_lossy(delivered[0].1), "hello")
  assert_eq(delivered[1].0, 2)
  assert_eq(@utf8.decode_lossy(delivered[1].1), "oops")
  assert_true(sink.finish() is None)
}

///|
test "frame sink keeps a truncated trailing payload at EOF" {
  let sink = FrameSink::new()
  ignore(
    sink.feed(
      Bytes::from_array([1, 0, 0, 0, 0, 0, 0, 10, b'p', b'a', b'r', b't']),
    ),
  )
  match sink.finish() {
    Some((ty, payload)) => {
      assert_eq(ty, 1)
      assert_eq(@utf8.decode_lossy(payload), "part")
    }
    None => fail("expected truncated payload to be delivered")
  }
}

///|
test "parse_log_head reads status, framing, and rejects raw streams" {
  let (status, framing) = parse_log_head(
    "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.multiplexed-stream",
    op="logs",
  )
  assert_eq(status, 200)
  assert_true(framing is LogFraming::CloseDelimited)
  let (_, chunked) = parse_log_head(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked",
    op="logs",
  )
  assert_true(chunked is LogFraming::Chunked)
  let (_, fixed) = parse_log_head(
    "HTTP/1.1 200 OK\r\nContent-Length: 42",
    op="logs",
  )
  assert_true(fixed is LogFraming::Fixed(42))
  try
    parse_log_head(
      "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.raw-stream",
      op="logs",
    )
  catch {
    EngineError::MalformedResponse(op="logs", ..) => ()
    err => fail("expected MalformedResponse, got \{err}")
  } noraise {
    _ => fail("expected raw-stream rejection")
  }
}

///|
/// Close-delimited follow response: head plus arbitrary body bytes, no
/// Content-Length (the engine keeps the stream open).
fn follow_head(content_type : String, body : Bytes) -> Bytes {
  let head = @utf8.encode(
    "HTTP/1.1 200 OK\r\nContent-Type: \{content_type}\r\nConnection: close\r\n\r\n",
  )
  let out : Array[Byte] = []
  for b in head {
    out.push(b)
  }
  for b in body {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
async test "1-shot logs demuxes both streams under the body limit" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
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
          http_stream_resp(
            "application/vnd.docker.multiplexed-stream",
            exec_frame(1, b"hello\n") + exec_frame(2, b"oops\n"),
          )
        },
        requests,
      )
    })
    let client = DockerClient::new(socket_path=sock)
    let logs = client.logs("abc")
    assert_eq(@utf8.decode_lossy(logs.stdout), "hello\n")
    assert_eq(@utf8.decode_lossy(logs.stderr), "oops\n")
    assert_eq(requests, [
      "GET /containers/abc/logs?stdout=1&stderr=1&follow=false&tail=all HTTP/1.1",
    ])
  })
}

///|
async test "1-shot logs fails on raw TTY stream content type" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
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
          http_stream_resp("application/vnd.docker.raw-stream", b"raw output")
        },
        [],
      )
    })
    let client = DockerClient::new(socket_path=sock)
    try client.logs("tty") catch {
      EngineError::MalformedResponse(op="logs", ..) => ()
      err => fail("expected MalformedResponse, got \{err}")
    } noraise {
      _ => fail("expected raw-stream rejection")
    }
  })
}

///|
async test "1-shot logs honors the injected body limit" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
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
          http_stream_resp(
            "application/vnd.docker.multiplexed-stream",
            exec_frame(1, b"0123456789abcdef"),
          )
        },
        [],
      )
    })
    let client = DockerClient::new(socket_path=sock)
    try client.logs("big", body_limit=8) catch {
      EngineError::BodyTooLarge(op="logs", limit=8) => ()
      err => fail("expected BodyTooLarge, got \{err}")
    } noraise {
      _ => fail("expected BodyTooLarge")
    }
  })
}

///|
async test "follow session delivers frames and ends at EOF" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
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
          follow_head(
            "application/vnd.docker.multiplexed-stream",
            exec_frame(1, b"line-1\n") +
            exec_frame(2, b"err\n") +
            exec_frame(0, b"ignored-stdin") +
            exec_frame(1, b"line-2\n"),
          )
        },
        [],
      )
    })
    let client = DockerClient::new(socket_path=sock)
    let session = DockerLogSession::new(id="abc")
    client.follow_logs(session)
    assert_true(session.is_ended())
    assert_eq(@utf8.decode_lossy(session.stdout()), "line-1\nline-2\n")
    assert_eq(@utf8.decode_lossy(session.stderr()), "err\n")
    assert_eq(session.stdout_dropped(), 0L)
    assert_true(session.error() is None)
  })
}

///|
/// Chunk sizes on the wire are hex (RFC 9112) — decimal "12" would be
/// read as 18 bytes and misalign the stream.
fn hex_len(n : Int32) -> String {
  let digits = "0123456789abcdef"
  let buf = StringBuilder()
  let mut v = n
  if v == 0 {
    buf.write_char('0')
  }
  while v > 0 {
    buf.write_char(digits[v % 16].unsafe_to_char())
    v = v / 16
  }
  // Digits were emitted least-significant first — reverse.
  let s = buf.to_string()
  let rev = StringBuilder()
  for i = s.length() - 1; i >= 0; i = i - 1 {
    rev.write_char(s[i].unsafe_to_char())
  }
  rev.to_string()
}

///|
async test "follow session de-chunks a chunked body" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  let body = exec_frame(1, b"chunked!") + exec_frame(2, b"e")
  // Emit the body as two chunks to exercise reassembly.
  let half = body.length() / 2
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        1,
        fn(_head) {
          let out : Array[Byte] = []
          for
            b in @utf8.encode(
              "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
            ) {
            out.push(b)
          }
          // chunk 1: first half, chunk 2: second half, then terminator
          for b in @utf8.encode("\{hex_len(body[:half].length())}\r\n") {
            out.push(b)
          }
          for b in body[:half].to_owned() {
            out.push(b)
          }
          for b in @utf8.encode("\r\n\{hex_len(body[half:].length())}\r\n") {
            out.push(b)
          }
          for b in body[half:].to_owned() {
            out.push(b)
          }
          for b in @utf8.encode("\r\n0\r\n\r\n") {
            out.push(b)
          }
          Bytes::from_array(out)
        },
        [],
      )
    })
    let client = DockerClient::new(socket_path=sock)
    let session = DockerLogSession::new(id="abc")
    client.follow_logs(session)
    assert_true(session.is_ended())
    assert_eq(@utf8.decode_lossy(session.stdout()), "chunked!")
    assert_eq(@utf8.decode_lossy(session.stderr()), "e")
    assert_true(session.error() is None)
  })
}

///|
async test "session.stop wakes a blocked follow read" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    // Server: answer the head + one frame, then hold the connection
    // open (a follow stream with no more output yet) until the client
    // stops — its shutdown turns our next read into EOF.
    group.spawn_bg(() => {
      let mut fd : Int32? = None
      for spin = 0; spin < 10_000 && fd is None; spin = spin + 1 {
        fd = unix_accept(listen_fd)
        if fd is None {
          @async.sleep(1)
        }
      }
      let conn = unix_socket_from_fd(fd.unwrap())
      defer conn.close()
      ignore(conn.read_until("\r\n\r\n"))
      conn.write_all(
        follow_head(
          "application/vnd.docker.multiplexed-stream",
          exec_frame(1, b"first\n"),
        ),
      )
      // Block until the client's shutdown gives us EOF (or an error).
      try conn.read_all() catch {
        _ => ()
      } noraise {
        _ => ()
      }
    })
    let client = DockerClient::new(socket_path=sock)
    let session = DockerLogSession::new(id="abc")
    group.spawn_bg(() => client.follow_logs(session))
    // Wait for delivery, then stop — bounded busy-wait.
    let mut saw = false
    for i = 0; i < 5_000; i = i + 1 {
      if session.stdout().length() > 0 {
        saw = true
        break
      }
      @async.sleep(1)
    }
    assert_true(saw)
    session.stop()
    let mut ended = false
    for i = 0; i < 5_000; i = i + 1 {
      if session.is_ended() {
        ended = true
        break
      }
      @async.sleep(1)
    }
    assert_true(ended)
    assert_true(session.error() is None)
    assert_eq(@utf8.decode_lossy(session.stdout()), "first\n")
  })
}

///|
async test "cancelling the reader task still ends the session" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      let mut fd : Int32? = None
      for spin = 0; spin < 10_000 && fd is None; spin = spin + 1 {
        fd = unix_accept(listen_fd)
        if fd is None {
          @async.sleep(1)
        }
      }
      let conn = unix_socket_from_fd(fd.unwrap())
      defer conn.close()
      ignore(conn.read_until("\r\n\r\n"))
      conn.write_all(
        follow_head(
          "application/vnd.docker.multiplexed-stream",
          exec_frame(1, b"first\n"),
        ),
      )
      // Hold the connection open until the cancelled reader closes it.
      try conn.read_all() catch {
        _ => ()
      } noraise {
        _ => ()
      }
    })
    let client = DockerClient::new(socket_path=sock)
    let session = DockerLogSession::new(id="abc")
    let task = group.spawn(
      () => client.follow_logs(session),
      allow_failure=true,
    )
    // Wait for first data, then cancel the consumer task — the reader's
    // defer must still close the socket and mark the session ended.
    for i = 0; i < 5_000 && session.stdout().length() == 0; i = i + 1 {
      @async.sleep(1)
    }
    task.cancel()
    let mut ended = false
    for i = 0; i < 5_000; i = i + 1 {
      if session.is_ended() {
        ended = true
        break
      }
      @async.sleep(1)
    }
    assert_true(ended)
  })
}

///|
async test "follow on a missing container lands in session.error" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        1,
        fn(_head) { http_resp("404", "Not Found", "{\"message\":\"gone\"}") },
        [],
      )
    })
    let client = DockerClient::new(socket_path=sock)
    let session = DockerLogSession::new(id="ghost")
    client.follow_logs(session)
    assert_true(session.is_ended())
    match session.error() {
      Some(EngineError::ContainerNotFound(..)) => ()
      _ => fail("expected ContainerNotFound in session.error")
    }
  })
}

///|
async test "follow respects the small injected buffer cap" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
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
          follow_head(
            "application/vnd.docker.multiplexed-stream",
            exec_frame(1, b"0123456789"),
          )
        },
        [],
      )
    })
    let client = DockerClient::new(socket_path=sock)
    let session = DockerLogSession::new(id="abc", buffer_limit=6)
    client.follow_logs(session)
    assert_true(session.is_ended())
    // 10 bytes through a 6-byte window: the first 4 are dropped.
    assert_eq(@utf8.decode_lossy(session.stdout()), "456789")
    assert_eq(session.stdout_dropped(), 4L)
  })
}
