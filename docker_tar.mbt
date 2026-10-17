///|
/// Minimal POSIX ustar builder for `PUT /containers/{id}/archive`
/// (issue 0033), mirroring upstream `docker_tar.rs`'s UstarBuilder:
/// 512-byte headers, octal fields, `ustar\0`/`00` magic, name/prefix
/// split for long paths, two zero blocks as trailer. Directories carry
/// a trailing `/`; files must not.

///|
/// Per-entry and whole-archive ceiling (bytes). Both the per-file
/// content and the finished tar including the trailer must fit.
pub const ARCHIVE_MAX_BYTES : Int64 = 67108864 // 64 MiB

///|
/// Upper bound on archive entries. Upstream has no constant (its
/// parser only reads the first entry and its builder writes
/// caller-controlled entries); MoonBit bounds the count so a hostile
/// or buggy walk cannot emit an unbounded header stream.
pub const ARCHIVE_MAX_ENTRIES : Int64 = 4096

///|
priv suberror TarError {
  TrailingSlash(String)
  MissingTrailingSlash(String)
  NameTooLong(String)
  BadName(String)
  TooLarge(limit~ : Int64)
  TooManyEntries(limit~ : Int64)
}

///|
priv struct TarBuilder {
  data : Array[Byte]
  mut total : Int64
  mut entries : Int64
  emitted_dirs : Map[String, Bool]
}

///|
fn TarBuilder::new() -> TarBuilder {
  { data: [], total: 0, entries: 0, emitted_dirs: {}, }
}

///|
fn TarBuilder::push(self : TarBuilder, bytes : Bytes) -> Unit raise {
  self.total += bytes.length().to_int64()
  guard self.total <= ARCHIVE_MAX_BYTES else {
    raise TooLarge(limit=ARCHIVE_MAX_BYTES)
  }
  for b in bytes {
    self.data.push(b)
  }
}

///|
fn octal_field(value : Int64, width : Int32) -> Bytes {
  let mut digits = ""
  let mut v = value
  if v == 0 {
    digits = "0"
  } else {
    while v > 0 {
      digits = (v % 8).to_int().to_string() + digits
      v = v / 8
    }
  }
  let field = String::make(width - 1 - digits.length(), '0') + digits + "\u0000"
  @utf8.encode(field)
}

///|
fn TarBuilder::header(
  self : TarBuilder,
  name~ : String,
  mode~ : Int64,
  uid~ : Int64,
  gid~ : Int64,
  size~ : Int64,
  mtime~ : Int64,
  typeflag~ : Byte,
) -> Unit raise {
  self.entries += 1
  guard self.entries <= ARCHIVE_MAX_ENTRIES else {
    raise TooManyEntries(limit=ARCHIVE_MAX_ENTRIES)
  }
  // Entry names are validated as *structure* before any
  // normalization could hide traversal: non-empty, no NUL, no
  // leading '/', no '..' or empty components, no component that is
  // only dots (a trailing '/' is legal only for directories, which
  // the callers enforce via the TrailingSlash/MissingTrailingSlash
  // guards).
  guard name.length() > 0 else { raise BadName("empty entry name") }
  for seg in name.split("/") {
    guard seg != ".." else {
      raise BadName("entry name must not contain '..': \{name}")
    }
  }
  // a bare "." segment or name would be normalized away by the
  // extractor — reject it while still visible
  guard name != "." else { raise BadName("entry name must not be '.'") }
  guard !name.contains("/./") else {
    raise BadName("entry name must not contain '/./': \{name}")
  }
  guard !name.has_suffix("/.") && !name.has_suffix("/./") else {
    raise BadName("entry name must not end with '.': \{name}")
  }
  for c in name {
    guard c != '\u{00}' else {
      raise BadName("entry name must not contain NUL: \{name}")
    }
  }
  guard !name.has_prefix("/") else {
    raise BadName("entry name must be relative: \{name}")
  }
  guard !name.contains("//") else {
    raise BadName("entry name must not contain '//': \{name}")
  }
  let header = FixedArray::make(512, b'\x00')
  // name/prefix split: name ≤ 100, else split at a '/' so that
  // tail ≤ 100 and head ≤ 155.
  let (name_part, prefix_part) = if name.length() <= 100 {
    (name, "")
  } else {
    let mut split_at = -1
    for i = name.length() - 1; i >= 0; i = i - 1 {
      if name[i] == '/' {
        let tail = name.length() - i - 1
        if tail <= 100 && i <= 155 {
          split_at = i
          break
        }
      }
    }
    guard split_at > 0 else { raise NameTooLong(name) }
    (name[split_at + 1:].to_owned(), name[:split_at].to_owned())
  }
  fn put(src : Bytes, at : Int32, max : Int32) -> Unit {
    for i = 0; i < src.length() && i < max; i = i + 1 {
      header[at + i] = src[i]
    }
  }
  put(@utf8.encode(name_part), 0, 100)
  put(octal_field(mode, 8), 100, 8)
  put(octal_field(uid, 8), 108, 8)
  put(octal_field(gid, 8), 116, 8)
  put(octal_field(size, 12), 124, 12)
  put(octal_field(mtime, 12), 136, 12)
  // checksum field is all spaces while computing
  for i = 148; i < 156; i = i + 1 {
    header[i] = b' '
  }
  header[156] = typeflag
  let magic = @utf8.encode("ustar")
  for i = 0; i < 5; i = i + 1 {
    header[257 + i] = magic[i]
  }
  header[262] = b'\x00'
  header[263] = b'0'
  header[264] = b'0'
  put(@utf8.encode(prefix_part), 345, 155)
  let mut sum : Int64 = 0
  for i = 0; i < 512; i = i + 1 {
    sum += header[i].to_int().to_int64()
  }
  // GNU-style: 6 octal digits + NUL + space; 7 digits + NUL when the
  // sum needs it (names of unusual bytes can exceed 6 digits).
  let mut chk = ""
  let mut s = sum
  while s > 0 {
    chk = (s % 8).to_int().to_string() + chk
    s = s / 8
  }
  let chk_field = if chk.length() <= 6 {
    String::make(6 - chk.length(), '0') + chk + "\u0000 "
  } else {
    chk + "\u0000"
  }
  put(@utf8.encode(chk_field), 148, 8)
  self.push(Bytes::from_array(header))
}

///|
/// Pad file content to a 512-byte boundary.
fn TarBuilder::pad(self : TarBuilder, size : Int64) -> Unit raise {
  let rem = size % 512
  if rem > 0 {
    self.push(Bytes::make(512 - rem.to_int(), b'\x00'))
  }
}

///|
/// Directory entry — `name` must end with `/`.
fn TarBuilder::append_directory(
  self : TarBuilder,
  name : String,
  mode~ : Int64 = 0o755,
) -> Unit raise {
  guard name.has_suffix("/") else { raise MissingTrailingSlash(name) }
  // repeated parent chains must not emit duplicate dir entries
  if self.emitted_dirs.contains(name) {
    return
  }
  self.emitted_dirs[name] = true
  self.header(name~, mode~, uid=0, gid=0, size=0, mtime=0, typeflag=b'5')
}

///|
/// File entry — `name` must not end with `/`.
fn TarBuilder::append_file(
  self : TarBuilder,
  name : String,
  mode~ : Int64,
  uid~ : Int64,
  gid~ : Int64,
  mtime~ : Int64,
  data : Bytes,
) -> Unit raise {
  guard !name.has_suffix("/") else { raise TrailingSlash(name) }
  self.header(
    name~,
    mode~,
    uid~,
    gid~,
    size=data.length().to_int64(),
    mtime~,
    typeflag=b'0',
  )
  self.push(data)
  self.pad(data.length().to_int64())
}

///|
/// Trailer (two zero blocks) plus the accumulated archive.
fn TarBuilder::finish(self : TarBuilder) -> Bytes raise {
  self.push(Bytes::make(1024, b'\x00'))
  Bytes::from_array(self.data)
}

///|
/// Parse-only errors for `GET /containers/{id}/archive` responses
/// (issue 0034), mirroring upstream `parse_first_regular_file_from_ustar`.
priv suberror TarReadError {
  EmptyArchive
  IsDirectory(String)
  UnsupportedEntry(String)
  GzippedArchive
  ChecksumMismatch(String)
  TruncatedData(name~ : String)
  BadHeader(String)
}

///|
/// Read an octal field terminated by NUL or space.
fn octal_parse(block : Bytes, at : Int32, width : Int32) -> Int64 raise {
  let mut v : Int64 = 0
  let mut saw = false
  for i = at; i < at + width; i = i + 1 {
    let c = block[i]
    if c >= b'0' && c <= b'7' {
      v = v * 8 + (c.to_int() - '0'.to_int()).to_int64()
      saw = true
    } else if c == b'\x00' || c == b' ' {
      break
    } else {
      raise BadHeader("non-octal byte in numeric field")
    }
  }
  if !saw {
    raise BadHeader("empty numeric field")
  }
  v
}

///|
/// Verify a header block: checksum matches and the ustar magic is
/// present. Returns the entry name.
fn verify_ustar_header(block : Bytes) -> String raise {
  let mut sum : Int64 = 0
  for i = 0; i < 512; i = i + 1 {
    sum += if i >= 148 && i < 156 { 32 } else { block[i].to_int().to_int64() }
  }
  let stored = octal_parse(block, 148, 8)
  guard stored == sum else {
    raise ChecksumMismatch("stored=\{stored} computed=\{sum}")
  }
  // POSIX ustar\0 and GNU "ustar " magic are both accepted.
  guard block[257] == b'u' &&
    block[258] == b's' &&
    block[259] == b't' &&
    block[260] == b'a' &&
    block[261] == b'r' else {
    raise BadHeader("missing ustar magic")
  }
  let mut end = 0
  while end < 100 && block[end] != b'\x00' {
    end += 1
  }
  @utf8.decode_lossy(block[:end].to_owned())
}

///|
/// Whether a 512-byte block is entirely zero (end-of-archive marker).
fn is_zero_block(block : Bytes) -> Bool {
  for i = 0; i < 512; i = i + 1 {
    if block[i] != b'\x00' {
      return false
    }
  }
  true
}

///|
/// `parse_first_regular_file_from_ustar` — interpret only the leading
/// entry of an archive response. A directory yields `IsDirectory`, an
/// all-zero/absent entry `EmptyArchive`, link/device/fifo entries and
/// gzip magic `UnsupportedEntry`/`GzippedArchive`, checksum or data
/// truncation a hard error. No partial payload is ever returned; the
/// declared size is bounds-checked against the actual buffer (no
/// capacity preallocation, matching upstream).
fn parse_first_regular_file(tar : Bytes) -> Bytes raise {
  if tar.length() < 512 {
    if tar.length() == 0 {
      raise EmptyArchive
    }
    // Non-zero bytes short of a full header — truncation, not
    // emptiness.
    raise BadHeader("header truncated at \{tar.length()} bytes")
  }
  if tar[0] == b'\x1f' && tar[1] == b'\x8b' {
    raise GzippedArchive
  }
  let head = tar[:512].to_owned()
  if is_zero_block(head) {
    raise EmptyArchive
  }
  let name = verify_ustar_header(head)
  let typeflag = head[156]
  guard typeflag == b'0' || typeflag == b'\x00' else {
    if typeflag == b'5' {
      raise IsDirectory(name)
    }
    raise UnsupportedEntry("\{name} (typeflag \{typeflag.to_int()})")
  }
  let size = octal_parse(head, 124, 12)
  guard size <= ARCHIVE_MAX_BYTES else {
    raise TooLarge(limit=ARCHIVE_MAX_BYTES)
  }
  let end = 512L + size
  guard end <= tar.length().to_int64() else { raise TruncatedData(name~) }
  tar[512:end.to_int()].to_owned()
}
