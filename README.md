# container.mbt

MoonBit-native port of [shiguredo/container-rs](https://github.com/shiguredo/container-rs). The original library exposes a testcontainers-like interface and uses **Apple Container XPC on macOS** and **Docker Engine API on Linux**.

**Status: initial, incomplete port.** The current code offers native MoonBit image configuration and a working-intent **CLI-backed lifecycle adapter** for \`docker\` and Apple's \`container\` command. It does **not** yet implement the original XPC client, direct Docker Engine HTTP transport, Drop/watchdog cleanup, dynamic port inspection, or full testcontainers parity. Platform integration has not been validated yet.

## Requirements

- MoonBit with native backend, \`moonbitlang/async\` 0.22.4.
- Linux with \`docker\` CLI and a running Docker-compatible engine.
- macOS 26 on Apple Silicon with Apple \`container\` installed and \`container system start\` completed.
- No Node.js, Python, Rust, or Docker Desktop dependency in the MoonBit library.

## API (first slice)

\`GenericImage\` provides \`new\`, \`with_cmd\`, \`with_env_var\`, \`with_label\`, \`with_entrypoint\`, \`with_container_name\`, \`with_mapped_port\`, \`with_exposed_port\`, \`with_mount\`, \`with_wait_for\`, and other options.

\`image.start(runtime)\` (or \`start_detected()\`) returns a container. \`container.exec(...)\`, \`logs()\`, \`stop()\`, and \`rm()\` are supported by the CLI adapter, and fixed port mappings can be read with \`get_host_port_ipv4\`. **Call \`rm()\` explicitly**, ideally in a cleanup branch; unlike the Rust library, this version does not clean up in Drop.

Supported waits: nothing, delay, stdout/stderr/either log string. Healthcheck/exit waits fail before container creation rather than silently skipping. An exposed port with host port 0 is Docker-only until Apple ephemeral publishing and runtime inspection are verified.

See [Porting status and roadmap](docs/PORTING.md) for exact differences. No claim of functional parity is made.

## Development

\`\`\`sh
moon update
moon check --target native --deny-warn
moon test --target native
moon build --target native
\`\`\`

The current tests are deterministic argument/API conformance tests; they do not start containers. Linux and macOS real-runtime E2E are pending. Do not merge without green CI and independent review.

## Provenance and license

Based on [shiguredo/container-rs](https://github.com/shiguredo/container-rs) \`develop\`, commit \`f68ba1ffed67c9c4e9abdb39212835d50d7afcf3\` (2026-10-07). Copyright 2026 Shiguredo Inc. Upstream and this port are under Apache License 2.0. This is an independent port, not an official Shiguredo release.
