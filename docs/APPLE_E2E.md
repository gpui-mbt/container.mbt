# Apple Container CLI E2E acceptance (M0)

**Status: NOT RUN.** The physical-host test is a mandatory platform acceptance gate for this PR. Passing the Linux Docker job does not imply Apple runtime compatibility. This verifies the temporary `container` CLI adapter, **not** the original Rust library's Apple Container XPC transport.

## Execution environment

- **Physical Apple Silicon Mac** with macOS **26+**. Intel Macs and virtualized macOS guests are not equivalent.
- `container` from [apple/container](https://github.com/apple/container) installed, with an available kernel and `container system start` completed.
- MoonBit CLI with native target; pinned `moonbitlang/async@0.22.4`; outbound registry access for `alpine:3.20`.
- Free host TCP port **18080**. Stop if already bound. Do **not** treat GitHub-hosted `macos-26` ARM64 runners as physical Macs: GitHub documents that nested virtualization is unsupported, so a passing macOS compile job would not prove Apple Container E2E.

## Run on the host

```sh
uname -m                           # arm64
sw_vers -productVersion            # 26.x or newer
container system version
container system start
container system status
lsof -nP -iTCP:18080 -sTCP:LISTEN  # should return no listener
moon update
moon check --target native --deny-warn
moon test --target native
moon run smoke_apple --target native
container list --all
```

The accepted `moon run` output is **`Apple Container lifecycle E2E PASS`**, with exit code 0. Capture the OS version, hardware architecture, `container system version`, the command log, and the final `container list --all` to provide evidence. The `smoke_apple` test must demonstrate actual Apple CLI `run --detach`, log readiness, fixed port mapping lookup, `exec`, `logs`, `stop`, `delete --force`, and absence of the test container after cleanup. It uses a unique name and never deletes all containers.

## Boundaries and explicit non-acceptance

- **NOT RUN:** The CLI smoke above has not been executed on a Mac as part of this PR.
- It checks the returned fixed port number, **not end-to-end host TCP connectivity**; verify network forwarding separately before claiming host-port conformance.
- Starting a container that fails during CLI `run` before its ID can be read may leave an orphan. The readiness-failure rollback test does not cover that case. Resolve or explicitly gate this P1 before merging.
- Apple Container XPC and Linux direct Docker Engine transport are outside M0. No XPC parity claim is permitted.
- Because Apple Container uses virtualization, do not report a GitHub-hosted macOS compile as an Apple Container runtime E2E PASS.

**Merge gate:** final HEAD Linux CI green + independent approve-equivalent review + this physical-host Apple test green + startup cleanup blocker resolved. Leave Draft until all gates are met.
