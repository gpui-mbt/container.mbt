///|
fn ustar_checksum_ok(block : Bytes) -> Bool {
  // checksum field holds spaces during the sum
  let mut sum = 0
  for i = 0; i < 512; i = i + 1 {
    sum += if i >= 148 && i < 156 { 32 } else { block[i].to_int() }
  }
  // stored field: octal digits then NUL/space
  let mut stored = 0
  for i = 148; i < 156; i = i + 1 {
    let c = block[i]
    if c >= b'0' && c <= b'7' {
      stored = stored * 8 + (c.to_int() - '0'.to_int())
    }
  }
  stored == sum
}

///|
fn ustar_name(block : Bytes) -> String {
  let mut end = 0
  while end < 100 && block[end] != b'\x00' {
    end += 1
  }
  let name = @utf8.decode_lossy(block[:end].to_owned())
  let mut pend = 0
  while pend < 155 && block[345 + pend] != b'\x00' {
    pend += 1
  }
  if pend > 0 {
    "\{@utf8.decode_lossy(block[345:345 + pend].to_owned())}/\{name}"
  } else {
    name
  }
}

///|
fn to_i(c : Byte) -> Int32 {
  c.to_int()
}

///|
/// 0033: a file entry serializes as 512 header + padded data; checksum,
/// magic, typeflag and name fields are structurally correct.
test "ustar file entry layout" {
  let b = TarBuilder::new()
  b.append_file(
    "work/config.txt",
    mode=0o644,
    uid=1000,
    gid=1000,
    mtime=0,
    @utf8.encode("hello"),
  )
  let tar = b.finish()
  assert_eq(tar.length(), 512 + 512 + 1024)
  assert_true(ustar_checksum_ok(tar[:512].to_owned()))
  assert_eq(ustar_name(tar[:512].to_owned()), "work/config.txt")
  assert_eq(to_i(tar[156]), '0'.to_int())
  // magic "ustar\0" + version "00"
  assert_eq(@utf8.decode_lossy(tar[257:262].to_owned()), "ustar")
  assert_eq(to_i(tar[263]), '0'.to_int())
  // data follows the header, then zero padding
  assert_eq(@utf8.decode_lossy(tar[512:517].to_owned()), "hello")
  // mode 0o644 → 7 octal digits + NUL in an 8-byte field
  assert_eq(@utf8.decode_lossy(tar[100:107].to_owned()), "0000644")
  for i = 1024; i < 2048; i = i + 1 {
    assert_eq(tar[i], b'\x00')
  }
}

///|
/// 0033: directory entries carry a trailing slash + '5' typeflag;
/// append_file rejects slash-terminated names and vice versa.
test "ustar directory vs file slash discipline" {
  let b = TarBuilder::new()
  b.append_directory("a/b/", mode=0o755)
  let tar = b.finish()
  assert_eq(to_i(tar[156]), '5'.to_int())
  assert_eq(ustar_name(tar[:512].to_owned()), "a/b/")
  let b2 = TarBuilder::new()
  let r1 = try {
    b2.append_file("x/", mode=0, uid=0, gid=0, mtime=0, b"")
    false
  } catch {
    _ => true
  }
  assert_true(r1)
  let r2 = try {
    b2.append_directory("x")
    false
  } catch {
    _ => true
  }
  assert_true(r2)
}

///|
/// 0033: names longer than 100 bytes split into prefix + name.
test "ustar long name prefix split" {
  let long = "d".repeat(60) + "/" + "f".repeat(50)
  let b = TarBuilder::new()
  b.append_file(long, mode=0, uid=0, gid=0, mtime=0, b"x")
  let tar = b.finish()
  assert_true(ustar_checksum_ok(tar[:512].to_owned()))
  assert_eq(ustar_name(tar[:512].to_owned()), long)
}

///|
/// 0033: target validation — all malformed forms rejected before any
/// daemon traffic.
test "copy target rejection matrix" {
  for
    bad in [
      "relative/path", "/", "/abs/", "/a//b", "/a/.", "/a/b/..", "/x/../y",
    ] {
    let r = try {
      ignore(validate_copy_target(bad))
      false
    } catch {
      _ => true
    }
    assert_true(r)
  }
  assert_eq(validate_copy_target("/work/config.txt"), "work/config.txt")
  assert_eq(validate_copy_target("/single"), "single")
}

///|
/// 0033: full direct-path flow — create → PUT archive → start on the
/// mock daemon; the PUT body is a parseable tar containing the file.
async test "copy-to uploads between create and start" {
  let dir = @fs.tmpdir(prefix="container-mbt-engine")
  let sock = "\{dir}/docker.sock"
  let listen_fd = unix_listen(sock)
  let captured : Array[String] = []
  let put_bodies : Array[Bytes] = []
  defer {
    (unix_close_fd(listen_fd) catch { _ => () }) |> ignore
    (@fs.remove(sock) catch { _ => () }) |> ignore
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_mock_engine(
        listen_fd,
        6,
        fn(request) {
          if request.has_prefix("GET /images/") {
            if captured.length() == 1 {
              return http_resp(
                "404", "Not Found", "{\"message\":\"no such image\"}",
              )
            }
            return http_200("{}")
          }
          if request.has_prefix("POST /images/create") {
            return http_200("{\"status\":\"ok\"}")
          }
          if request.has_prefix("PUT /containers/") {
            let idx = request[:].find("\r\n\r\n")
            match idx {
              Some(i) =>
                put_bodies.push(@utf8.encode(request[i + 4:].to_owned()))
              None => ()
            }
            return http_200("")
          }
          if request.has_prefix("POST /containers/create") {
            return http_resp("201", "Created", "{\"Id\":\"cid\"}")
          }
          http_resp("204", "No Content", "")
        },
        captured,
      )
    })
    let client = DockerClient::new(socket_path=sock)
    let image = GenericImage::new("alpine", "3.20").with_copy_to(
      "/work/config.txt",
      CopyDataSource::data(@utf8.encode("hello")),
      mode=0o640,
      uid=1000,
    )
    let container = image.start_with_client(client)
    assert_eq(container.id(), "cid")
  })
  assert_eq(put_bodies.length(), 1)
  let tar = put_bodies[0]
  // work/ dir + file hdr + one data block + 2-block trailer = 5 blocks
  assert_eq(tar.length(), 512 * 5)
  assert_eq(ustar_name(tar[:512].to_owned()), "work/")
  assert_eq(to_i(tar[156]), '5'.to_int())
  assert_eq(ustar_name(tar[512:1024].to_owned()), "work/config.txt")
  assert_true(ustar_checksum_ok(tar[512:1024].to_owned()))
  assert_eq(@utf8.decode_lossy(tar[1024:1029].to_owned()), "hello")
}

///|
/// 0033: a copy PUT failure rolls the created container back and
/// surfaces the PUT error, not a cleanup error.
async test "copy failure removes the created container" {
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
        6,
        fn(request) {
          if request.has_prefix("GET /images/") {
            if captured.length() == 1 {
              return http_resp(
                "404", "Not Found", "{\"message\":\"no such image\"}",
              )
            }
            return http_200("{}")
          }
          if request.has_prefix("POST /images/create") {
            return http_200("{\"status\":\"ok\"}")
          }
          if request.has_prefix("PUT /containers/") {
            return http_resp(
              "500", "Server Error", "{\"message\":\"tar fail\"}",
            )
          }
          if request.has_prefix("POST /containers/create") {
            return http_resp("201", "Created", "{\"Id\":\"cid\"}")
          }
          http_resp("204", "No Content", "")
        },
        captured,
      )
    })
    let client = DockerClient::new(socket_path=sock)
    let image = GenericImage::new("alpine", "3.20").with_copy_to(
      "/f.txt",
      CopyDataSource::data(b"x"),
    )
    let msg = try {
      ignore(image.start_with_client(client))
      "<no error>"
    } catch {
      err => "\{err}"
    }
    assert_true(msg.contains("tar fail"))
  })
  assert_true(
    captured.iter().any(fn(r) { r.has_prefix("DELETE /containers/cid") }),
  )
}

///|
/// 0033: invalid target — rejected at with_copy_to, zero requests.
test "invalid target fails before any traffic" {
  let image = GenericImage::new("alpine", "3.20")
  let r = try {
    ignore(image.with_copy_to("relative", CopyDataSource::data(b"x")))
    false
  } catch {
    _ => true
  }
  assert_true(r)
}

///|
/// 0033: File source — real file + directory recursion + symlink
/// rejection against the host fs.
async test "file and directory sources" {
  let dir = @fs.tmpdir(prefix="container-mbt-copy")
  @fs.write_file("\{dir}/a.txt", @utf8.encode("alpha"))
  @fs.mkdir("\{dir}/sub", permission=0o755)
  @fs.write_file("\{dir}/sub/b.txt", @utf8.encode("beta"))
  @fs.symlink("\{dir}/link"[:], target="a.txt"[:], force_symlink=true)
  // symlink as the copy root is rejected outright
  let bad = GenericImage::new("alpine", "3.20").with_copy_to(
    "/dest",
    CopyDataSource::file("\{dir}/link"),
  )
  let r = try {
    ignore(bad.build_copy_archive())
    false
  } catch {
    _ => true
  }
  assert_true(r)
  // directory recursion produces parent + nested entries
  let img = GenericImage::new("alpine", "3.20").with_copy_to(
    "/dest",
    CopyDataSource::file("\{dir}/sub"),
  )
  let tar = img.build_copy_archive()
  // directory contents land under the target: dest/ + dest/b.txt
  assert_eq(tar.length(), 512 * 5)
  assert_eq(ustar_name(tar[:512].to_owned()), "dest/")
  assert_eq(ustar_name(tar[512:1024].to_owned()), "dest/b.txt")
  assert_eq(@utf8.decode_lossy(tar[1024:1028].to_owned()), "beta")
  // single file source → one entry at the target path
  let one = GenericImage::new("alpine", "3.20").with_copy_to(
    "/dest/a.txt",
    CopyDataSource::file("\{dir}/a.txt"),
  )
  let tar2 = one.build_copy_archive()
  assert_eq(tar2.length(), 512 * 5)
  assert_eq(ustar_name(tar2[:512].to_owned()), "dest/")
  assert_eq(ustar_name(tar2[512:1024].to_owned()), "dest/a.txt")
  assert_eq(@utf8.decode_lossy(tar2[1024:1029].to_owned()), "alpha")
}

///|
/// 0033: CLI adapters report copy-to as not-yet-implemented before
/// any side effect; DirectDocker supports it.
test "cli adapters reject copy-to" {
  for adapter in [CliDocker, CliApple] {
    assert_true(capability(adapter, CopyTo) is NotYetImplemented(_))
  }
  assert_true(capability(DirectDocker, CopyTo) is Supported)
}

///|
/// 0033: the 64 MiB ceiling applies to the *whole archive* including
/// headers, padding and trailer — exact fit passes, one byte over fails.
test "archive size ceiling is exact" {
  // header(512) + data + trailer(1024); data is already 512-aligned here
  let fit = TarBuilder::new()
  fit.append_file(
    "f",
    mode=0,
    uid=0,
    gid=0,
    mtime=0,
    Bytes::make((ARCHIVE_MAX_BYTES - 1536).to_int(), b'x'),
  )
  assert_eq(fit.finish().length().to_int64(), ARCHIVE_MAX_BYTES)
  let over = TarBuilder::new()
  let r = try {
    over.append_file(
      "f",
      mode=0,
      uid=0,
      gid=0,
      mtime=0,
      Bytes::make((ARCHIVE_MAX_BYTES - 1535).to_int(), b'x'),
    )
    over.finish() |> ignore
    false
  } catch {
    _ => true
  }
  assert_true(r)
}

///|
/// 0033: quotes and spaces in paths are data, not syntax — they
/// validate and round-trip through ustar headers untouched.
test "quoted and spaced paths pass through" {
  for ok in ["/q'uote/f\"x", "/dir with space/file", "/a.b/c.d"] {
    ignore(validate_copy_target(ok))
  }
  let b = TarBuilder::new()
  b.append_file("we'ird/na\"me", mode=0, uid=0, gid=0, mtime=0, b"q")
  let tar = b.finish()
  assert_eq(ustar_name(tar[:512].to_owned()), "we'ird/na\"me")
  assert_true(ustar_checksum_ok(tar[:512].to_owned()))
}

///|
/// 0033: a 404 on the archive PUT is classified as ContainerNotFound
/// (0017 matrix), not an opaque failure.
async test "archive put 404 classifies as ContainerNotFound" {
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
        fn(_request) {
          http_resp("404", "Not Found", "{\"message\":\"no such container\"}")
        },
        captured,
      )
    })
    let client = DockerClient::new(socket_path=sock)
    let classified = try {
      client.put_container_archive("ghost", b"")
      "<no error>"
    } catch {
      EngineError::ContainerNotFound(op="copy to container", container="ghost") =>
        "not-found:ghost"
      err => "other:\{err}"
    }
    assert_eq(classified, "not-found:ghost")
  })
}
