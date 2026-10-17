// Apple Container XPC start path (issue 0026): resolve/pull -> create ->
// bootstrap -> start -> copy-to -> readiness, with rollback limited to
// the attempt's own ID.

///|
async fn xpc_copy_to(id : String, image : GenericImage) -> Unit raise {
  for copy in image.copy_to {
    let target = copy.target
    match copy.source {
      File(path) => {
        copy_in(id, path, target, copy.mode.to_int())
      }
      Data(bytes) => {
        let dir = @fs.tmpdir(prefix="container-mbt-xpc-copy")
        let path = "\{dir}/payload"
        @fs.write_file(path, bytes, permission=0o600)
        errdefer (@fs.remove(path) catch { _ => () })
        copy_in(id, path, target, copy.mode.to_int())
        @fs.remove(path)
      }
    }
  }
}

///|
pub async fn GenericImage::start_with_xpc(self : GenericImage) -> Container {
  guard is_apple() else {
    fail("Apple Container XPC is only available on macOS")
  }
  let deadline = Deadline::after(self.startup_timeout_ms)
  preflight(DirectXpc, self)
  validate_image_request(self)
  ensure_bind_sources_exist(self)
  ignore(ensure_owner_lock())
  let attempt = RunAttempt::prepare(self)
  let attempt_image = self
    .snapshot()
    .with_container_name(attempt.name())
    .with_label(OWNERSHIP_LABEL, attempt.owner_id())
  let kernel : Bytes? = match attempt_image.kernel {
    Some(path) => {
      guard path.has_prefix("/") else {
        fail("kernel path must be absolute: \{path}")
      }
      guard @fs.exists(path) else {
        fail("kernel path is not a file: \{path}")
      }
      let is_dir = try {
        let _ = @fs.readdir(path)
        true
      } catch {
        _ => false
      } noraise {
        v => v
      }
      guard !is_dir else {
        fail("kernel path is not a file: \{path}")
      }
      Some(kernel_json(path))
    }
    None => None
  }
  let descriptor = resolve_or_pull(
    attempt_image.descriptor(),
    attempt_image.platform,
  )
  let image_config = resolve_image_config(descriptor, attempt_image.platform)
  let config = build_container_config(
    attempt_image,
    attempt.name(),
    descriptor,
    image_config,
  )
  let id = attempt.name()
  let mut created = false
  let mut registered = false
  errdefer {
    if registered {
      unregister_xpc(id)
    }
    if created {
      try remove_container(id, true) catch { _ => () }
    }
  }
  create_container(config, kernel)
  created = true
  bootstrap_container(id)
  start_process(id, id)
  xpc_copy_to(id, attempt_image)
  let env = build_env(attempt_image)
  register_xpc({ id, env, })
  registered = true
  let container : Container = {
    id,
    runtime: AppleContainer,
    mappings: attempt_image.mappings.copy(),
    removed: false,
    resolved_ports: None,
    inspect_obj: None,
    client: None,
  }
  container.wait_ready_until(
    attempt_image.ready_conditions.copy(),
    @async.now() + deadline.remaining_ms(),
  )
  container
}
