# Porting matrix — shiguredo/container-rs to container.mbt

Upstream reference: `shiguredo/container-rs@f68ba1ffed67c9c4e9abdb39212835d50d7afcf3` (develop, 2026-10-07).

| Capability | Upstream Rust | Current MoonBit | Next action |
|---|---|---|---|
| GenericImage / descriptor / CMD / env overrides | Yes | Implemented, pure MoonBit | Expand upstream regression fixtures |
| TCP/UDP/SCTP port type | Yes | Implemented, checked range | Add string parsing and native port inspection |
| ContainerRequest / labels / mounts | Yes | Partial, CLI args | Expand settings and parity contract |
| Apple Container on macOS | XPC native bridge | CLI adapter only, unverified | Port XPC request/response and fd handling; Apple Silicon E2E |
| Linux containers | Docker Engine HTTP over Unix socket | Direct Engine transport (pull/create/start/inspect/stop/rm/wait/exec/logs); CLI adapter retained for Apple | Real daemon E2E in CI (issue 0020) |
| Start / exec / stop / rm / logs | Async + sync APIs | Engine API + async CLI methods | Real runtime E2E, bounded output follow modes |
| Readiness | log / duration / HTTP / health / exit | log and duration only | Implement remaining strategies, timeouts and cancellation |
| Dynamic host port / bridge IP | Yes | Implemented via `NetworkSettings.Ports`/`Networks` inspection (IPv4/IPv6, protocol-aware) | Real-daemon verification in CI |
| Registry auth | Static `auths` (`DOCKER_AUTH_CONFIG`/`DOCKER_CONFIG`/`~/.docker`) | Implemented; `X-Registry-Auth` on pull/resolve. Credential helpers (`credsStore`/`credHelpers`) intentionally unsupported | Private-registry E2E in CI |
| Copy to/from container | `PUT`/`GET /containers/{id}/archive` | Implemented on the direct adapter: `with_copy_to` (create→archive→start, in-memory tar ≤ 64 MiB and ≤ 4096 entries (ARCHIVE_MAX_ENTRIES), parents 0o755, rollback on failure) and `copy_file_from`/`copy_file_to_host` (first-entry ustar parse, dir/link/gzip/truncation rejected, 404 splits path-missing vs container-missing) | Real-daemon E2E in CI; path-security sweep (0035) |
| Graceful cleanup / keep | Drop / explicit rm / watchdog | Explicit rm only | Safe scoped lifecycle helpers and watchdog |
| Networking / platform / permissions | Broad feature coverage | Small subset | Add separately with host-specific tests |
| Mac/Ubuntu E2E | Extensive | Linux Docker lifecycle smoke in CI; macOS pending | Native runners and host observability |

## Architecture

1. **MoonBit core:** configuration, validation, readiness models, argument construction and public container operations.
2. **Direct adapters (default):** Docker Engine HTTP over the Unix socket on Linux (M1, issues 0006-0019; compatibility boundary for rootless/Podman runtimes is recorded in [ENGINE_COMPATIBILITY.md](ENGINE_COMPATIBILITY.md)); Apple Container XPC on Apple Silicon macOS (M2, issues 0023-0032). Runtime adapters must not influence the public API.
3. **CLI adapters (explicit only):** `moonbitlang/async/shell` process spawn with argv arrays, selected only through `start_cli` — `start` never falls back to them. Kept until the direct adapters' E2E acceptance criteria (0020/0032) are met, then removed. No shell string evaluation or Node.js.

## Compatibility and safety constraints

- Refuse unsupported options before creating a container rather than pretending parity.
- Never execute user-provided shell snippets. Runtime arguments are an argv array, not a shell command.
- Reject duplicate port mappings and invalid container IDs before network pull or container creation.
- Use bounded captured output; log retrieval is not a streaming substitute for the original LogConsumer.
- Explicit `rm` is mandatory for now. No automatic cleanup contract is implemented.
- Current CLI mode cannot claim upstream's Docker Desktop-free XPC behavior or API-level error classification.
- Keep upstream revision pinned for feature comparison, and preserve attribution and license.

## Acceptance milestones

**M0 (this PR):** MoonBit native API, CLI command construction, lifecycle adapter, deterministic conformance tests and Linux Docker lifecycle smoke. The CLI adapter is still not equivalent to upstream's direct Docker Engine/XPC transport.

**M1:** Linux Docker Engine API transport + image pull/start/exec/logs/stop/rm, rollback, port inspection, process-crash tests.

**M2:** Apple Container XPC with Apple Silicon tests (macOS 26), logging and fd ownership, cleanup. The separate M0 CLI smoke acceptance is described in [APPLE_E2E.md](APPLE_E2E.md), and must not be mistaken for XPC compatibility.

**M3:** Full documented parity matrix: copy, health/HTTP/exit waits, credential helpers, volumes/networks, resource configuration, fault and timeout coverage. Merge only after CI green and approve-equivalent independent review.
