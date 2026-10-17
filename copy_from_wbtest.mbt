///|
/// 0034: a well-formed tar yields the first file's payload.
test "parse_first_regular_file happy path" {
  let b = TarBuilder::new()
  b.append_file("work/out.txt", mode=0o644, uid=0, gid=0, mtime=0, b"payload")
  let got = parse_first_regular_file(b.finish())
  assert_eq(@utf8.decode_lossy(got[:]), "payload")
}

///|
/// 0034: leading directory entry → IsDirectory; an all-zero or short
/// buffer → EmptyArchive.
test "parse rejects directory and empty archives" {
  let b = TarBuilder::new()
  b.append_directory("dir/", mode=0o755)
  let r1 = try {
    ignore(parse_first_regular_file(b.finish()))
    "ok"
  } catch {
    TarReadError::IsDirectory(_) => "dir"
    _ => "other"
  }
  assert_eq(r1, "dir")
  let r2 = try {
    ignore(parse_first_regular_file(b""))
    "ok"
  } catch {
    TarReadError::EmptyArchive => "empty"
    _ => "other"
  }
  assert_eq(r2, "empty")
  let zeros = Bytes::make(2048, b'\x00')
  let r3 = try {
    ignore(parse_first_regular_file(zeros))
    "ok"
  } catch {
    TarReadError::EmptyArchive => "empty"
    _ => "other"
  }
  assert_eq(r3, "empty")
}

///|
/// 0034: link/device/fifo typeflags and gzip magic are rejected.
test "parse rejects non-regular entries" {
  for flag in [b'1', b'2', b'3', b'4', b'6', b'x'] {
    let b = TarBuilder::new()
    // hand-roll a header: reuse append_file layout then flip typeflag
    b.append_file("f", mode=0, uid=0, gid=0, mtime=0, b"")
    let mut tar = b.finish()
    let arr = FixedArray::make(tar.length(), b'\x00')
    for i = 0; i < tar.length(); i = i + 1 {
      arr[i] = tar[i]
    }
    arr[156] = flag
    // recompute checksum (offset 148..155 treated as spaces)
    let mut sum : Int64 = 0
    for i = 0; i < 512; i = i + 1 {
      sum += if i >= 148 && i < 156 { 32 } else { arr[i].to_int().to_int64() }
    }
    let mut chk = ""
    let mut sv = sum
    while sv > 0 {
      chk = (sv % 8).to_int().to_string() + chk
      sv = sv / 8
    }
    let field = String::make(6 - chk.length(), '0') + chk + "\u{0000} "
    let fb = @utf8.encode(field)
    for i = 0; i < fb.length(); i = i + 1 {
      arr[148 + i] = fb[i]
    }
    tar = Bytes::from_array(arr)
    let r = try {
      ignore(parse_first_regular_file(tar))
      "ok"
    } catch {
      TarReadError::UnsupportedEntry(_) => "unsupported"
      e => "other:\{e}"
    }
    assert_eq(r, "unsupported")
  }
  // gzip magic at archive start
  let gz = Bytes::from_array([b'\x1f', b'\x8b', 0, 0, 0])
  let padded = FixedArray::make(1024, b'\x00')
  for i = 0; i < gz.length(); i = i + 1 {
    padded[i] = gz[i]
  }
  let r2 = try {
    ignore(parse_first_regular_file(Bytes::from_array(padded)))
    "ok"
  } catch {
    TarReadError::GzippedArchive => "gzip"
    _ => "other"
  }
  assert_eq(r2, "gzip")
}

///|
/// 0034: checksum mismatch and truncated payload are hard errors.
test "parse rejects corrupt tar" {
  let b = TarBuilder::new()
  b.append_file("f", mode=0, uid=0, gid=0, mtime=0, b"data")
  let tar = b.finish()
  // corrupt the checksum
  let arr = FixedArray::make(tar.length(), b'\x00')
  for i = 0; i < tar.length(); i = i + 1 {
    arr[i] = tar[i]
  }
  arr[148] = b'7'
  let bad = Bytes::from_array(arr)
  let r1 = try {
    ignore(parse_first_regular_file(bad))
    "ok"
  } catch {
    TarReadError::ChecksumMismatch(_) => "checksum"
    e => "other:\{e}"
  }
  assert_eq(r1, "checksum")
  // truncate inside the declared 4-byte payload
  let cut = tar[:514].to_owned()
  let r2 = try {
    ignore(parse_first_regular_file(cut))
    "ok"
  } catch {
    TarReadError::TruncatedData(name="f") => "truncated"
    e => "other:\{e}"
  }
  assert_eq(r2, "truncated")
}

///|
/// 0034: 404 splits — daemon "Could not find the file " → path
/// missing; any other 404 → container missing.
async test "archive 404 classification" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let captured : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        3,
        fn(request) {
          if request.contains("path=%2Fmissing") {
            return http_resp(
              "404", "Not Found", "{\"message\":\"Could not find the file /missing in container cid\"}",
            )
          }
          return http_resp(
            "404", "Not Found", "{\"message\":\"no such container\"}",
          )
        },
        captured,
      )
    })
    let client = DockerClient::new(socket_path=sock)
    let r1 = try {
      ignore(client.copy_file_from("cid", "/missing"))
      "ok"
    } catch {
      EngineError::ContainerPathNotFound(path="/missing", ..) =>
        "path-not-found"
      e => "other:\{e}"
    }
    assert_eq(r1, "path-not-found")
    let r2 = try {
      ignore(client.copy_file_from("gone", "/x"))
      "ok"
    } catch {
      EngineError::ContainerNotFound(container="gone", ..) =>
        "container-not-found"
      e => "other:\{e}"
    }
    assert_eq(r2, "container-not-found")
    // empty 404 body → container missing (safe default)
    let r3 = try {
      ignore(client.copy_file_from("gone2", "/x"))
      "ok"
    } catch {
      EngineError::ContainerNotFound(..) => "container-not-found"
      e => "other:\{e}"
    }
    assert_eq(r3, "container-not-found")
  })
}

///|
/// 0034: end-to-end — mock daemon returns a tar; bytes and host-file
/// forms both deliver the payload.
async test "copy_file_from returns bytes end to end" {
  let b = TarBuilder::new()
  b.append_file("app/result.txt", mode=0o644, uid=0, gid=0, mtime=0, b"42")
  let tar = b.finish()
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let captured : Array[String] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        1,
        fn(_request) { http_200_bin(tar) },
        captured,
      )
    })
    let client = DockerClient::new(socket_path=sock)
    let bytes = client.copy_file_from("cid", "/app/result.txt")
    assert_eq(@utf8.decode_lossy(bytes[:]), "42")
    assert_eq(
      captured[0],
      "GET /containers/cid/archive?path=%2Fapp%2Fresult.txt HTTP/1.1",
    )
  })
}

///|
fn http_200_bin(body : Bytes) -> Bytes {
  let head = @utf8.encode(
    "HTTP/1.1 200 OK\r\nContent-Length: \{body.length()}\r\nConnection: close\r\n\r\n",
  )
  let out = FixedArray::make(head.length() + body.length(), b'\x00')
  for i = 0; i < head.length(); i = i + 1 {
    out[i] = head[i]
  }
  for i = 0; i < body.length(); i = i + 1 {
    out[head.length() + i] = body[i]
  }
  Bytes::from_array(out)
}
