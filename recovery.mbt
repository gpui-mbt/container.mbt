///|
/// Orphan detection and bounded recovery (issue 0021). Containers are
/// attributed to their creating process via the `container-mbt.owned`
/// label holding a process owner id; liveness is proven by an flock the
/// owner holds for its whole lifetime. Only containers whose owner is
/// demonstrably dead are removed — never anything else.

///|
/// One row of `GET /containers/json` reduced to what recovery needs.
pub struct ListedContainer {
  id : String
  name : String
  /// `Labels["container-mbt.owned"]` — `None` when absent/foreign.
  owner : String?
}

///|
/// Recovery outcome: removed ids, per-container skip reasons, and
/// per-container delete failures — all three are distinct diagnostics.
pub struct RecoveryReport {
  removed : Array[String]
  skipped : Array[(String, String)]
  failed : Array[(String, String)]
}

///|
fn RecoveryReport::new() -> RecoveryReport {
  { removed: [], skipped: [], failed: [], }
}

///|
/// Human-readable evidence line for run logs.
pub fn RecoveryReport::summary(self : RecoveryReport) -> String {
  "removed=\{self.removed.length()} skipped=\{self.skipped.length()} failed=\{self.failed.length()}"
}

///|
/// `GET /containers/json?all=true&filters={"label":[...]}` — server
/// filters by label presence; the client still re-checks the label
/// value so a permissive server can never widen the blast radius.
pub async fn DockerClient::list_owned_containers(
  self : DockerClient,
  deadline? : Deadline,
) -> Array[ListedContainer] {
  let filters = "{\"label\":[\"container-mbt.owned\"]}"
  let resp = self.request(
    verb="GET",
    path="/containers/json?all=true&filters=\{percent_encode(filters)}",
    op="list owned containers",
    context=EngineOp::container_lifecycle(),
    target="containers",
    deadline?,
  )
  let json = try @json.parse(@utf8.decode_lossy(resp.body)) catch {
    err =>
      raise EngineError::MalformedResponse(
        op="list owned containers",
        detail=err.to_string(),
      )
  } noraise {
    j => j
  }
  let out : Array[ListedContainer] = []
  guard json is Array(items) else { return out }
  for item in items {
    guard item is Object(obj) else { continue }
    let id = match obj.get("Id") {
      Some(String(s)) => s
      _ => continue
    }
    let name = match obj.get("Names") {
      Some(Array([String(n), ..])) =>
        if n.has_prefix("/") {
          n[1:].to_owned()
        } else {
          n
        }
      _ => ""
    }
    let owner = match obj.get("Labels") {
      Some(Object(labels)) =>
        match labels.get(OWNERSHIP_LABEL) {
          Some(String(v)) => Some(v)
          _ => None
        }
      _ => None
    }
    out.push({ id, name, owner, })
  }
  out
}

///|
/// Detect and remove this daemon's orphaned containers: those carrying
/// our ownership label whose owner lock is acquirable (= owner dead).
/// Bounded by `limit` per call; removal failures are aggregated, not
/// raised, so one bad entry cannot hide the rest. Explicit opt-in API —
/// never called from `start` automatically.
pub async fn DockerClient::recover_orphaned_containers(
  self : DockerClient,
  limit~ : Int32 = 32,
  lock_dir~ : String = owner_lock_dir(),
  deadline? : Deadline,
) -> RecoveryReport {
  let report = RecoveryReport::new()
  let listed = self.list_owned_containers(deadline?)
  for c in listed {
    if report.removed.length() >= limit {
      report.skipped.push((c.id, "recovery limit reached"))
      continue
    }
    match c.owner {
      None =>
        // Defensive: server-side filter should already exclude these.
        report.skipped.push((c.id, "no container-mbt.owned label"))
      Some(owner) =>
        if !valid_owner_id(owner) {
          report.skipped.push((c.id, "malformed owner label: \{owner}"))
        } else {
          let alive = owner_alive(lock_dir, owner) catch {
            err =>
              raise EngineError::TransportError(
                op="recover orphans",
                detail="owner lock probe failed: \{err}",
              )
          }
          if alive {
            report.skipped.push((c.id, "owner \{owner} still alive"))
          } else {
            try self.remove_container(c.id, force=true, deadline?) catch {
              err => report.failed.push((c.id, "\{err}"))
            } noraise {
              _ => report.removed.push(c.id)
            }
          }
        }
    }
  }
  report
}
