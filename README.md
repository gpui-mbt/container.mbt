# container.mbt

MoonBit-native port of [shiguredo/container-rs](https://github.com/shiguredo/container-rs). The original library exposes a testcontainers-like interface and uses **Apple Container XPC on macOS** and **Docker Engine API on Linux**.

**Status: M0/M1/M2 runtime paths implemented.** The library offers native MoonBit image configuration, a **direct Docker Engine API adapter** on Linux (HTTP over the Unix socket — no `docker` CLI process), and a **native Apple Container XPC adapter** on Apple Silicon (pull/create/start/exec/logs/stop/rm, dynamic ports, bridge/gateway, bind/tmpfs/volume mounts, post-start copy, masked/readonly paths, SSH and custom kernel). The `docker`/`container` CLI adapters remain available through the explicit `start_cli` selection only; `start` never falls back to them. Linux Docker integration is tested in CI; the XPC path passed a physical Apple Silicon E2E on 2026-10-17 on Apple Container 1.5.0. Full testcontainers parity is not claimed.

## Requirements

- MoonBit with native backend, `moonbitlang/async` 0.22.4.
- Linux with a running Docker-compatible engine (Unix socket at `/var/run/docker.sock` by default; explicit `DockerClient::new(socket_path~)` selects another socket — no implicit discovery). Rootless and Podman compatibility is a measured-boundary record in [docs/ENGINE_COMPATIBILITY.md](docs/ENGINE_COMPATIBILITY.md), not a support claim. The `docker` CLI is only needed for the explicit `start_cli` adapter.
- macOS 26 on Apple Silicon with Apple `container` 1.5.0+ installed and `container system start` completed.
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

Apple Container on macOS 26 (Apple Silicon) — native XPC, no `container` CLI process:

```moonbit
let container = image.start(@container.AppleContainer)
```

The explicit CLI fallback remains `image.start_cli(@container.AppleContainer)` for comparison only.

Supported waits: `nothing`, `millis`, `millis_in_env_var`, `message_on_stdout`/`stderr`/`either`, `http`, `healthcheck`, `exit_code` (latter four on the direct Docker path; CLI adapters reject them preflight). Container options include `with_name`/`with_tag` overrides, mounts (`bind`/`volume`/`tmpfs` with size/mode), `with_hostname`/`with_host_addr`/`with_host_gateway`, `with_privileged`/`with_cap_add`/`with_cap_drop`/`with_shm_size`/`with_init`, `with_healthcheck`, and `with_copy_to` for pre-start file injection.

Cleanup contract: `with_container` scopes best-effort removal (suppressed by exact `TESTCONTAINERS_COMMAND=keep`), and a process-lifetime watchdog reaps owned Docker containers on abnormal exit. Containers started via plain `start`/`start_cli` still require an **explicit `rm()`**.

See [Porting status and roadmap](docs/PORTING.md) for exact differences. No claim of functional parity is made.

## Support matrix

| OS | Runtime | Minimum version | Status | Notes |
|---|---|---|---|---|
| Linux | Docker Engine (Unix socket) | API 1.44+ (Docker 25+) | PASS (native tests + CI smoke) | direct adapter; rootless/Podman boundary in [ENGINE_COMPATIBILITY.md](docs/ENGINE_COMPATIBILITY.md) |
| Linux | `docker` CLI | Docker 25+ | PASS (native tests; CI smoke planned) | explicit `start_cli` only |
| macOS 26 | Apple `container` | 1.5.0 tested | PASS (native XPC E2E incl. copy-in, volume, masked/readonly, SSH, custom kernel) | no `container` CLI in the XPC path — see [APPLE_E2E.md](docs/APPLE_E2E.md) |

Incompatibilities to know: explicit `rm()` is required outside `with_container`; the public API is `async` only (no sync facade — see docs/PORTING.md); native backend only (`supported_targets = "native"`).

## Development

```sh
moon update
moon check --target native --deny-warn
moon test --target native
moon build --target native
```

On macOS, run the XPC-only smoke with a `PATH` that cannot resolve `container`:

```sh
moon build --target native
env -i HOME="$HOME" PATH=/usr/bin:/bin \
  _build/native/debug/build/smoke_xpc/smoke_xpc.exe
```

The unit tests are deterministic argument/API conformance tests plus live XPC handshake tests on macOS. CI has separate `native` and `docker-e2e` jobs; the latter runs the Docker daemon smoke and the direct-API E2E with artifacts. Apple Silicon E2E (`smoke_apple/`, `smoke_xpc/`) is recorded in [Apple Container acceptance](docs/APPLE_E2E.md), not in a GitHub-hosted macOS job. Do not merge without green CI, an independent approve-equivalent review and platform acceptance.

## Provenance and license

Based on [shiguredo/container-rs](https://github.com/shiguredo/container-rs) `develop`, commit `f68ba1ffed67c9c4e9abdb39212835d50d7afcf3` (2026-10-07). Copyright 2026 Shiguredo Inc. Upstream and this port are under Apache License 2.0. This is an independent port, not an official Shiguredo release.
