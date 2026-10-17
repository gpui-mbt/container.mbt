# container.mbt

MoonBit-native port of [shiguredo/container-rs](https://github.com/shiguredo/container-rs). The original library exposes a testcontainers-like interface and uses **Apple Container XPC on macOS** and **Docker Engine API on Linux**.

**Status: initial, incomplete port.** The current code offers native MoonBit image configuration and, on Linux, a **direct Docker Engine API adapter** (HTTP over the Unix socket — no `docker` CLI process) covering pull/create/start/inspect/stop/rm/wait/exec/logs, pre-start `with_copy_to` archive upload, dynamic port resolution, bridge IP inspection, and static registry auth. The `docker`/`container` CLI adapters remain available through the explicit `start_cli` selection only; `start` never falls back to them. The original XPC client (Apple Silicon), Drop/watchdog cleanup, and full testcontainers parity are not yet implemented. Linux Docker runtime integration is tested in CI. The Apple Container path has not been tested on an Apple Silicon host.

## Requirements

- MoonBit with native backend, `moonbitlang/async` 0.22.4.
- Linux with a running Docker-compatible engine (Unix socket at `/var/run/docker.sock` by default; explicit `DockerClient::new(socket_path~)` selects another socket — no implicit discovery). Rootless and Podman compatibility is a measured-boundary record in [docs/ENGINE_COMPATIBILITY.md](docs/ENGINE_COMPATIBILITY.md), not a support claim. The `docker` CLI is only needed for the explicit `start_cli` adapter.
- macOS 26 on Apple Silicon with Apple `container` installed and `container system start` completed.
- No Node.js, Python, Rust, or Docker Desktop dependency in the MoonBit library.

## Quickstart

Docker on Linux (direct Engine API — no `docker` CLI needed):

```moonbit
async fn main {
  let image = @container.GenericImage::new("alpine", "3.20")
    .with_cmd(["tail", "-f", "/dev/null"])
    .with_wait_for(@container.WaitFor::millis(500))
  // with_container runs the body and always removes the container.
  image.with_container(@container.Docker, container => {
    let out = container.exec(["sh", "-c", "printf hello"])
    println(out.stdout())
  })
}
```

Apple Container on macOS 26 (Apple Silicon) — **unverified** until the M2 XPC path lands; the CLI adapter exists but covers a subset:

```moonbit
let container = image.start_cli(@container.AppleContainer)
```

Supported waits: `nothing`, `millis`, `millis_in_env_var`, `message_on_stdout`/`stderr`/`either`, `http`, `healthcheck`, `exit_code` (latter four on the direct Docker path; CLI adapters reject them preflight). Container options include `with_name`/`with_tag` overrides, mounts (`bind`/`volume`/`tmpfs` with size/mode), `with_hostname`/`with_host_addr`/`with_host_gateway`, `with_privileged`/`with_cap_add`/`with_cap_drop`/`with_shm_size`/`with_init`, `with_healthcheck`, and `with_copy_to` for pre-start file injection.

Cleanup contract: `with_container` scopes best-effort removal (suppressed by exact `TESTCONTAINERS_COMMAND=keep`), and a process-lifetime watchdog reaps owned Docker containers on abnormal exit. Containers started via plain `start`/`start_cli` still require an **explicit `rm()`**.

See [Porting status and roadmap](docs/PORTING.md) for exact differences. No claim of functional parity is made.

## Support matrix

| OS | Runtime | Minimum version | Status | Notes |
|---|---|---|---|---|
| Linux | Docker Engine (Unix socket) | API 1.44+ (Docker 25+) | PASS (native tests + CI smoke) | direct adapter; rootless/Podman boundary in [ENGINE_COMPATIBILITY.md](docs/ENGINE_COMPATIBILITY.md) |
| Linux | `docker` CLI | Docker 25+ | PASS (native tests; CI smoke planned) | explicit `start_cli` only |
| macOS 26 | Apple `container` | container 1.2.0 | 未実行 (physical Mac required) | CLI adapter subset; XPC adapter is M2 (issues 0023–0032) |

Incompatibilities to know: explicit `rm()` is required outside `with_container`; the public API is `async` only (no sync facade — see docs/PORTING.md); native backend only (`supported_targets = "native"`).

## Development

```sh
moon update
moon check --target native --deny-warn
moon test --target native
moon build --target native
```

The unit tests are deterministic argument/API conformance tests. The Linux GitHub Actions job additionally runs a Docker daemon-backed smoke exercise in `smoke/` using the real Alpine image, including the readiness-failure cleanup path. macOS Apple Silicon real-runtime E2E is pending; see [Apple Container manual acceptance](docs/APPLE_E2E.md) and `smoke_apple/`. Do not merge without green CI, an independent approve-equivalent review and platform acceptance.

## Provenance and license

Based on [shiguredo/container-rs](https://github.com/shiguredo/container-rs) `develop`, commit `f68ba1ffed67c9c4e9abdb39212835d50d7afcf3` (2026-10-07). Copyright 2026 Shiguredo Inc. Upstream and this port are under Apache License 2.0. This is an independent port, not an official Shiguredo release.
