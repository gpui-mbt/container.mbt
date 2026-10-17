///|
/// Issue 0044 — tmpfs size/mode options, AccessMode, bind-source
/// preflight, and per-runtime tmpfs-option capability.

///|
test "tmpfs size suffixes follow upstream base-1000" {
  let cases : Array[(String, Int64)] = [
    ("100", 100),
    ("100k", 100000),
    ("100K", 100000),
    ("5m", 5000000),
    ("2G", 2000000000),
    ("0", 0),
  ]
  for (spec, want) in cases {
    let got : Int64? = TmpfsOptions::new().with_size(spec).size_bytes catch {
        _ => {
          fail("size \{spec} unexpectedly raised")
          None
        }
      }
    assert_eq(got, Some(want))
  }
}

///|
fn raises(f : () -> TmpfsOptions raise) -> Bool {
  try {
    ignore(f())
    false
  } catch {
    _ => true
  }
}

///|
test "tmpfs size rejects malformed and overflowing specs" {
  for
    spec in [
      "", "abc", "-5", "10x", "5.5m", "k", "99999999999999999999", "9999999999g",
    ] {
    assert_true(raises(() => TmpfsOptions::new().with_size(spec)))
  }
  assert_true(raises(() => TmpfsOptions::new().with_size_bytes(-1L)))
  assert_true(raises(() => TmpfsOptions::new().with_mode(-1)))
}

///|
test "tmpfs options serialize into docker run --mount keys" {
  let opts = TmpfsOptions::new().with_size("4m").with_mode(0o1777)
  let image = GenericImage::new("alpine", "latest").with_mount(
    Mount::tmpfs_mount_options("/scratch", opts).with_read_only(),
  )
  let args = build_run_args(
    Docker,
    image,
    attempt=fixture_attempt("tmpfs-container", "fixture-run-id"),
  ).join(" ")
  assert_true(
    args.contains(
      "--mount type=tmpfs,target=/scratch,tmpfs-size=4000000,tmpfs-mode=1777,readonly",
    ),
  )
}

///|
test "tmpfs option builders ignore non-tmpfs mounts" {
  let mount = Mount::bind_mount("/h", "/c")
  let updated = mount.with_size("10m").with_mode(0o777)
  // Upstream drops MountTmpfsOptions on non-tmpfs mounts at reflection
  // time; our representation cannot even carry them there.
  if updated is Tmpfs(_, _, _) {
    fail("tmpfs options must not change a bind mount")
  }
  let plain = Mount::tmpfs_mount("/run")
  if plain is Tmpfs(_, _, opts) &&
    (opts.size_bytes is Some(_) || opts.mode is Some(_)) {
    fail("tmpfs_mount must not invent options")
  }
}

///|
test "tmpfs options reach the Engine API Mounts entry" {
  let opts = TmpfsOptions::new().with_size_bytes(1024L).with_mode(0o777)
  let image = GenericImage::new("alpine", "latest")
    .with_container_name("tmpfs-container")
    .with_mount(Mount::tmpfs_mount_options("/scratch", opts))
  let body = create_request(image).to_json()
  assert_true(
    body.contains(
      "{\"Type\":\"tmpfs\",\"Target\":\"/scratch\",\"ReadOnly\":false,\"TmpfsOptions\":{\"SizeBytes\":1024,\"Mode\":511}}",
    ),
  )
  // No options configured → no TmpfsOptions member at all.
  let bare = create_request(
    GenericImage::new("alpine", "latest").with_mount(Mount::tmpfs_mount("/run")),
  ).to_json()
  assert_true(!bare.contains("TmpfsOptions"))
}

///|
test "tmpfs options trip the capability matrix only when set" {
  let plain = GenericImage::new("a", "1").with_mount(Mount::tmpfs_mount("/x"))
  assert_true(!settings_in_use(plain).iter().any(fn(s) { s is TmpfsOptions }))
  let sized = GenericImage::new("a", "1").with_mount(
    Mount::tmpfs_mount("/x").with_size_bytes(1L),
  )
  assert_true(settings_in_use(sized).iter().any(fn(s) { s is TmpfsOptions }))
  // Verdicts: direct Docker + Docker CLI document tmpfs-size/tmpfs-mode;
  // the Apple CLI has no such notation → rejected before side effects.
  assert_true(capability(DirectDocker, TmpfsOptions) is Supported)
  assert_true(capability(CliDocker, TmpfsOptions) is Supported)
  match capability(CliApple, TmpfsOptions) {
    Rejected(reason) => assert_true(reason.contains("tmpfs"))
    _ => fail("CliApple must reject tmpfs options")
  }
}

///|
async test "bind source existence is checked before side effects" {
  let missing = GenericImage::new("a", "1").with_mount(
    Mount::bind_mount("/definitely-not-here-0044", "/c"),
  )
  let message = try {
    ensure_bind_sources_exist(missing)
    ""
  } catch {
    Failure::Failure(msg) => msg
    _ => "non-failure error"
  }
  assert_true(message.contains("bind mount source does not exist"))
  // Volume sources and present paths pass.
  let ok = GenericImage::new("a", "1")
    .with_mount(Mount::bind_mount("/tmp", "/c"))
    .with_mount(Mount::volume_mount("named", "/v"))
    .with_mount(Mount::tmpfs_mount("/t"))
  ensure_bind_sources_exist(ok)
}
