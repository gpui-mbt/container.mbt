# Engine API compatibility matrix (issue 0022)

Status of the direct Engine-API adapter (`start(Docker)` path) across
Docker Engine API compatible runtimes. The default socket is
`/var/run/docker.sock`; a different socket is selected explicitly via
`DockerClient::new(socket_path~)` — there is no automatic discovery or
fallback (per the 0019 explicit-selection rule).

Cell values: **PASS** (measured — date, runtime version, evidence
linked) / **FAIL** (error text recorded) / **未実行** (reason given).
No empty cells, no unmeasured "supported" claims.

## Operation matrix

| operation | Docker Engine rootful | Docker rootless | Podman rootless |
|---|---|---|---|
| socket connect | 未実行 — no daemon in dev env; exercised by CI `smoke_linux` step; error classes (missing/permission/refused) verified by wbtest against real unix sockets | 未実行 — no rootless Docker env available | 未実行 — no Podman env available |
| `GET /_ping` reachability | 未実行 — same as above | 未実行 | 未実行 |
| API version detect (`/version`, ≥1.24 gate) | 未実行 — version-preflight logic mock-verified | 未実行 | 未実行 |
| image pull | 未実行 — mock-verified incl. JSON-stream errors | 未実行 | 未実行 |
| create + start | 未実行 — mock-verified incl. rollback | 未実行 | 未実行 |
| wait/readiness | 未実行 — mock + unit verified | 未実行 | 未実行 |
| exec | 未実行 — mock-verified incl. non-zero exit | 未実行 — uid semantics unverified | 未実行 — uid semantics unverified |
| logs | 未実行 — mock-verified incl. chunked/multiplexed frames | 未実行 | 未実行 |
| inspect (ports) | 未実行 — mock-verified | 未実行 | 未実行 |
| inspect (bridge IP) | 未実行 — mock-verified | 未実行 — rootless networking may not expose bridge IPs | 未実行 — Podman network model differs |
| stop | 未実行 — mock-verified incl. idempotent 304/404 | 未実行 | 未実行 |
| rm | 未実行 — mock-verified incl. idempotent 404 | 未実行 | 未実行 |
| dynamic host port (`HostPort: 0`) | 未実行 — mock-verified | 未実行 | 未実行 |
| orphan recovery (label + flock) | 未実行 — mock-verified; CI `smoke_crash` kill -9 fixture pending | 未実行 | 未実行 |

## Connect-failure diagnostics (verified)

These were verified locally against real unix sockets (wbtest), not
mocks — they hold on any Engine-compatible socket:

| condition | error |
|---|---|
| socket path absent | `TransportError` / `SocketMissing` — "socket path … does not exist (is the daemon running?)" |
| permission denied | `TransportError` / `PermissionDenied` — "permission denied opening …" |
| listener refused | `TransportError` / `Refused` — "connection refused by …" |
| non-HTTP / malformed response | `MalformedResponse` or `Truncated` (framing) |

A missing socket and a permission problem are never conflated.

## Rootless-specific constraints

To be measured when a rootless environment is available; nothing here
is claimed verified:

| constraint | status |
|---|---|
| publishing host ports < 1024 | 未実行 |
| user-defined vs default network mode | 未実行 |
| bridge IP availability (`NetworkSettings.Networks`) | 未実行 |
| exec process uid vs `--user` handling | 未実行 |
| bind-mount permission mapping (rootless uid shift) | 未実行 |

## Candidate socket paths (unverified)

Recorded as candidates only — do not treat as discovered defaults:

- Docker rootless: `$XDG_RUNTIME_DIR/docker.sock`
- Podman rootless: `$XDG_RUNTIME_DIR/podman/podman.sock`

Both require explicit `DockerClient::new(socket_path~)`; the library
never probes them implicitly.

## Measurement procedure

On a Linux host with the runtime installed:

1. Point the client at the runtime socket:
   `DockerClient::new(socket_path="<runtime socket>")`.
2. Run the same sequence `smoke_linux` performs:
   preflight → pull → create+start → wait → exec → logs → inspect →
   stop → rm → inspect-404.
3. Record per-cell result, runtime name+version, and the raw error for
   FAIL cells; update this file and cite the run log.

CI does not gate on rootless/Podman cells (0022 is a boundary record,
not an acceptance gate).
