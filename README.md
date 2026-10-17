# container.mbt

MoonBit-native port of [shiguredo/container-rs](https://github.com/shiguredo/container-rs). The original library exposes a testcontainers-like interface and uses **Apple Container XPC on macOS** and **Docker Engine API on Linux**.

**Status: initial, incomplete port.** The current code offers native MoonBit image configuration and, on Linux, a **direct Docker Engine API adapter** (HTTP over the Unix socket — no `docker` CLI process) covering pull/create/start/inspect/stop/rm/wait/exec/logs, pre-start `with_copy_to` archive upload, dynamic port resolution, bridge IP inspection, and static registry auth. The `docker`/`container` CLI adapters remain available through the explicit `start_cli` selection only; `start` never falls back to them. The original XPC client (Apple Silicon), Drop/watchdog cleanup, and full testcontainers parity are not yet implemented. Linux Docker runtime integration is tested in CI. The Apple Container path has not been tested on an Apple Silicon host.

## Requirements

- MoonBit with native backend, `moonbitlang/async` 0.22.4.
- Linux with a running Docker-compatible engine (Unix socket at `/var/run/docker.sock` by default; explicit `DockerClient::new(socket_path~)` selects another socket — no implicit discovery). Rootless and Podman compatibility is a measured-boundary record in [docs/ENGINE_COMPATIBILITY.md](docs/ENGINE_COMPATIBILITY.md), not a support claim. The `docker` CLI is only needed for the explicit `start_cli` adapter.
- macOS 26 on Apple Silicon with Apple `container` installed and `container system start` completed.
- No Node.js, Python, Rust, or Docker Desktop dependency in the MoonBit library.

## API (first slice)

`GenericImage` provides `new`, `with_cmd`, `with_env_var`, `with_label`, `with_entrypoint`, `with_container_name`, `with_mapped_port`, `with_exposed_port`, `with_mount`, `with_wait_for`, and other options.

`image.start(runtime)` (or `start_detected()`) returns a container through the runtime's direct adapter — the Docker Engine API on Linux. `image.start_cli(runtime)` selects the `docker`/`container` CLI adapter explicitly. `container.exec(...)`, `logs()`, `stop()`, `rm()`, `get_host_port_ipv4`/`get_host_port_ipv6`, and `get_bridge_ip_address` work on both adapters; on the direct adapter no CLI process is ever spawned. Published mappings are snapshotted when the CLI run starts; later image-builder mutations cannot change the container's reported ports. **Call `rm()` explicitly**, ideally in a cleanup branch; unlike the Rust library, this version does not clean up in Drop.

Supported waits: nothing, delay, stdout/stderr/either log string. A shared startup deadline uses the MoonBit async timer clock; the CLI run command, each readiness condition, polling sleep, and log subprocess receive only the remaining budget. Rollback cleanup runs separately after readiness failure. **A CLI launch that times out before its container ID is known can still leave a runtime-owned container behind; this is an open startup-cleanup blocker.** Healthcheck/exit waits fail before container creation rather than silently skipping. An exposed port with host port 0 is Docker-only until Apple ephemeral publishing and runtime inspection are verified.

See [Porting status and roadmap](docs/PORTING.md) for exact differences. No claim of functional parity is made.

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
