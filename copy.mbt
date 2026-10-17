///|
/// `with_copy_to` (issue 0033): a source payload delivered to the
/// container via `PUT /containers/{id}/archive` between create and
/// start, so init can read files from its first instruction.

///|
/// Payload source: a host path (file or directory, recursed) or an
/// in-memory byte string.
pub enum CopyDataSource {
  File(String)
  Data(Bytes)
}

///|
/// A host filesystem source — a regular file or a directory that is
/// walked recursively.
pub fn CopyDataSource::file(path : String) -> CopyDataSource {
  File(path)
}

///|
/// An in-memory payload source.
pub fn CopyDataSource::data(bytes : Bytes) -> CopyDataSource {
  Data(bytes)
}

///|
/// One copy request: absolute container `target` path plus metadata
/// applied to file entries (intermediate directories always 0o755).
pub struct CopyTarget {
  target : String
  mode : Int64
  uid : Int64
  gid : Int64
  source : CopyDataSource
}

///|
/// Target validation (rejects before any daemon traffic): absolute,
/// no trailing `/`, no `..`, no `//`, no terminal `.`, has a filename,
/// and not the bare root. Returns the tar-relative form (no leading
/// `/`) which is what the archive actually carries.
fn validate_copy_target(target : String) -> String raise {
  guard target.has_prefix("/") else {
    fail("copy target must be an absolute path: \{target}")
  }
  guard target != "/" else {
    fail("copy target must not be the root directory: \{target}")
  }
  guard !target.has_suffix("/") else {
    fail("copy target must not end with '/': \{target}")
  }
  guard !target.contains("//") else {
    fail("copy target must not contain '//': \{target}")
  }
  guard !target.has_suffix("/.") && !target.has_suffix(".") else {
    fail("copy target must not end with '.': \{target}")
  }
  for seg in target.split("/") {
    guard seg != ".." else {
      fail("copy target must not contain '..': \{target}")
    }
  }
  for c in target {
    guard c != '\u{00}' else {
      fail("copy target must not contain NUL: \{target}")
    }
  }
  // leading '/' removed — archive paths are relative to the put root
  target[1:].to_owned()
}

///|
/// Builder API: copy `source` into the container at absolute `target`.
/// Fails here for malformed targets so the error is raised before any
/// container exists.
pub fn GenericImage::with_copy_to(
  self : GenericImage,
  target : String,
  source : CopyDataSource,
  mode~ : Int64 = 0o644,
  uid~ : Int64 = 0,
  gid~ : Int64 = 0,
) -> GenericImage raise {
  ignore(validate_copy_target(target))
  self.copy_to.push({ target, mode, uid, gid, source, })
  self
}

///|
/// Append parent-directory entries (0o755) for a tar-relative file
/// path, then the file path itself is appended by the caller.
fn TarBuilder::push_parents(self : TarBuilder, rel : String) -> Unit raise {
  let mut i = 0
  while i < rel.length() {
    if rel[i] == '/' {
      self.append_directory(rel[:i + 1].to_owned(), mode=0o755)
    }
    i = i + 1
  }
}

///|
/// Expand one copy request into archive entries. Host directories are
/// walked depth-first with deterministic (sorted) order; regular files
/// inside keep the target's mode/uid/gid, directories are 0o755.
/// Symlinks and non-regular sources are rejected (upstream contract).
async fn TarBuilder::push_copy_to(self : TarBuilder, copy : CopyTarget) -> Unit {
  let rel = validate_copy_target(copy.target)
  match copy.source {
    Data(bytes) => {
      self.push_parents(rel)
      self.append_file(
        rel,
        mode=copy.mode,
        uid=copy.uid,
        gid=copy.gid,
        mtime=0,
        bytes,
      )
    }
    File(path) =>
      match @fs.kind(path, follow_symlink=false) {
        @fs.FileKind::Regular => {
          let size = @fs.file_size(path)
          guard size <= ARCHIVE_MAX_BYTES else {
            fail("copy source exceeds 64 MiB: \{path}")
          }
          let data = @fs.read_file(path).binary()
          // TOCTOU: detect growth between the size check and the read.
          guard data.length().to_int64() <= size else {
            fail("copy source grew while reading: \{path}")
          }
          let (mtime_secs, _mtime_ns) = @fs.mtime(path)
          self.push_parents(rel)
          self.append_file(
            rel,
            mode=copy.mode,
            uid=copy.uid,
            gid=copy.gid,
            mtime=mtime_secs,
            data,
          )
        }
        @fs.FileKind::Directory =>
          // Recursion: rel is the target dir; children go under it.
          self.push_dir_tree(path, rel, copy)
        @fs.FileKind::SymLink =>
          fail("copy source must not be a symlink: \{path}")
        _ => fail("copy source must be a regular file or directory: \{path}")
      }
  }
}

///|
/// Walk a host directory depth-first into `rel` (the archive-side
/// directory, no leading slash).
async fn TarBuilder::push_dir_tree(
  self : TarBuilder,
  host_dir : String,
  rel : String,
  copy : CopyTarget,
) -> Unit {
  self.push_parents(rel)
  self.append_directory("\{rel}/", mode=0o755)
  let entries = @fs.readdir(host_dir, include_special=false, sort=true)
  for entry in entries {
    let host_child = "\{host_dir}/\{entry}"
    let rel_child = "\{rel}/\{entry}"
    match @fs.kind(host_child, follow_symlink=false) {
      @fs.FileKind::Directory => self.push_dir_tree(host_child, rel_child, copy)
      @fs.FileKind::Regular => {
        let size = @fs.file_size(host_child)
        guard size <= ARCHIVE_MAX_BYTES else {
          fail("copy source exceeds 64 MiB: \{host_child}")
        }
        let data = @fs.read_file(host_child).binary()
        guard data.length().to_int64() <= size else {
          fail("copy source grew while reading: \{host_child}")
        }
        let (mtime_secs, _mtime_ns) = @fs.mtime(host_child)
        self.append_file(
          rel_child,
          mode=copy.mode,
          uid=copy.uid,
          gid=copy.gid,
          mtime=mtime_secs,
          data,
        )
      }
      @fs.FileKind::SymLink =>
        fail("copy source must not be a symlink: \{host_child}")
      _ =>
        fail("copy source must be a regular file or directory: \{host_child}")
    }
  }
}

///|
/// Build the archive bytes for all pending copy requests — called
/// between create and start by the direct adapter.
async fn GenericImage::build_copy_archive(self : GenericImage) -> Bytes {
  let b = TarBuilder::new()
  for copy in self.copy_to {
    b.push_copy_to(copy)
  }
  b.finish()
}
