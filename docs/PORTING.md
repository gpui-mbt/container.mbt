# Porting matrix — shiguredo/container-rs to container.mbt

Upstream reference: `shiguredo/container-rs@f68ba1ffed67c9c4e9abdb39212835d50d7afcf3` (develop, 2026-10-07).

| Capability | Upstream Rust | Current MoonBit | Next action |
|---|---|---|---|
| GenericImage / descriptor / CMD / env overrides | Yes | Implemented, pure MoonBit | Expand upstream regression fixtures |
| TCP/UDP/SCTP port type | Yes | Implemented, checked range | Add string parsing and native port inspection |
| ContainerRequest / labels / mounts | Yes | Partial, CLI args | Expand settings and parity contract |
| Apple Container on macOS | XPC native bridge | CLI adapter only, unverified | Port XPC request/response and fd handling; Apple Silicon E2E |
| Linux containers | Docker Engine HTTP over Unix socket | Docker CLI adapter only, unverified | Replace CLI path with native MoonBit Docker Engine transport |
| Start / exec / stop / rm / logs | Async + sync APIs | Async CLI methods | Real runtime E2E, error classification, bounded output |
| Readiness | log / duration / HTTP / health / exit | log and duration only | Implement remaining strategies, timeouts and cancellation |
| Dynamic host port / bridge IP | Yes | Fixed host ports only | Runtime inspection |
| Copy in/out | Yes | Not implemented | Tar stream and path validation |
| Graceful cleanup / keep | Drop / explicit rm / watchdog | Explicit rm only | Safe scoped lifecycle helpers and watchdog |
| Networking / platform / permissions | Broad feature coverage | Small subset | Add separately with host-specific tests |
| Mac/Ubuntu E2E | Extensive | Linux Docker lifecycle smoke in CI; macOS pending | Native runners and host observability |

## Architecture

1. **MoonBit core:** configuration, validation, readiness models, argument construction and public container operations.
2. **Temporary adapters:** native `moonbitlang/async/shell` process spawn with argv arrays. No shell string evaluation or Node.js.
3. **Future parity adapters:** direct Docker Engine API on Linux and Apple Container XPC on Apple Silicon macOS. Runtime adapters must not influence the public API.

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

**M2:** Apple Container XPC with Apple Silicon tests (macOS 26), logging and fd ownership, cleanup.

**M3:** Full documented parity matrix: copy, health/HTTP/exit waits, registry auth, volumes/networks, resource configuration, fault and timeout coverage. Merge only after CI green and approve-equivalent independent review.
