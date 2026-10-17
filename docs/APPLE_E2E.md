# Apple Container CLI E2E acceptance (M0)

**Status: M0 CLI and XPC PASS on a physical Apple Silicon host (2026-10-17).** The command-line smoke below passed on macOS 26.5.2 / arm64 with Apple Container 1.5.0 (the first run used 0.12.3). This verifies the temporary `container` CLI adapter, **not** the original Rust library's Apple Container XPC transport. The XPC acceptance has its own section below.

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

- **M0 CLI: PASS on 2026-10-17.** See the last-run evidence below.
- The host port is configurable with `CONTAINER_MBT_APPLE_PORT` for re-runs. On the acceptance host, 18080 was already held by an unrelated user process (`madobe-sh`), so the observed PASS used the same fixed-mapping mechanism on 18081; 18080 itself was recorded as 未実行 for that host. The smoke fails explicitly when its configured port is occupied.
- The smoke now covers end-to-end host TCP connectivity (the earlier caveat is obsolete) and the CLI `run` failure-before-ID orphan path.
- Apple Container XPC has its own section below. It is not an M0 CLI result, and M0 CLI is not an XPC result. Linux direct Docker Engine transport is outside this document.
- Because Apple Container uses virtualization, do not report a GitHub-hosted macOS compile as an Apple Container runtime E2E PASS.

## Last run (2026-10-17)

- Host: physical Apple Silicon, `arm64`, macOS `26.5.2` (build `25F84`).
- Apple Container: CLI `1.5.0`, apiserver `1.5.0` (the first M0 run used `0.12.3`).
- Command: `PATH="/Users/fu2hito/usr/local/bin:$PATH" CONTAINER_MBT_APPLE_PORT=18081 moon run smoke_apple --target native`.
- Result: exit 0, `Apple Container lifecycle E2E PASS`.
- Covered: real `run --detach`, startup marker readiness, fixed `18081:80/tcp` mapping, host TCP `GET /` returning `moonbit-apple-tcp`, `exec`, `logs`, `stop`, `delete --force`, absence after removal, invalid-entrypoint run failure with no orphan, and survival of a foreign container.
- After the run, `container list --all` was empty (no test leftovers).
- Raw evidence: `docs/evidence/2026-10-17-apple-m0/`.

## XPC native acceptance (issue 0032)

- Command (no `container` CLI on `PATH`):
  ```sh
  moon build --target native
  env -i HOME="$HOME" PATH=/usr/bin:/bin \
    _build/native/debug/build/smoke_xpc/smoke_xpc.exe
  ```
- Result on 2026-10-17: exit 0,
  `Apple XPC lifecycle E2E PASS (host_port=... fds=6->7)`.
- Covered: pull/resolve (OCI index → manifest → config), `containerCreate`,
  `containerBootstrap`, `containerStartProcess`, readiness on stdout,
  exec stdout/stderr/exit 3, 1 MB bounded output, dynamic hostPort=0 with a
  host TCP `GET /` returning `moonbit-xpc-tcp`, bind / read-only bind /
  tmpfs mounts, one-shot `logs`, live `subscribe_logs` ticks, stop,
  repeated stop, remove, repeated remove, and no test container left in
  `container list --all`.
- FD count: 6 before, 7 after (one transient XPC connection descriptor);
  the smoke asserts no growth beyond one and the timeout probe settles.
- Apple Container 1.5.0 extra cases (`smoke_xpc_extra`, run via
  `script/verify_apple_container_1_5.sh`): **PASS**
  - copy-in (`copy_to` Data → `/copied`, read back `copy-data`)
  - volume mount (write/read `/vol/x`)
  - masked path (`/etc/passwd` not readable)
  - read-only path (`/etc/hosts` write rejected)
  - `with_ssh()` start
  - custom kernel (`~/Library/Application Support/com.apple.container/kernels/vmlinux-...`)
- Historical 0.12.3 limits (before the 2026-10-17 update):
  `containerCopyIn` returned `Connection interrupted`; masked/readonly and
  volume live E2E could not run. These are now PASS on 1.5.0.
- `containerStop` on 0.12.3 expected an Int32 signal; the bridge sends
  15/9 and retries the string form for newer servers. 1.5.0 stop/rm
  passed.
- Raw evidence: `docs/evidence/2026-10-17-apple-xpc-1.5.0/`
  (and the earlier 0.12.3 run in `docs/evidence/2026-10-17-apple-xpc/`).
- The XPC acceptance is distinct from the M0 CLI acceptance; neither may
  substitute for the other.

**Merge gate:** final HEAD Linux CI green + independent approve-equivalent review + this physical-host Apple test green + startup cleanup blocker resolved. Leave Draft until all gates are met.

## PR evidence template

Paste the following into the PR body or an artifact comment:

- Date (Asia/Tokyo):
- HEAD SHA:
- Host: physical Apple Silicon / macOS version / arch
- Apple Container: `container system version` output
- Command and exit code (M0 and/or XPC):
- Raw log location:
- `container list --all` before / after:
- FD count before / after (XPC):
- Published port and host TCP result (M0/XPC):
- Explicit 未実行 items and reason:

## Updating Apple Container (host step)

The agent sandbox cannot write `/Users/fu2hito/usr/local` or operate
launchd, so the host update must be run once from a normal Terminal
(no `sudo` is needed for this user-local prefix):

```sh
cd /Users/fu2hito/src/container.mbt
script/update_apple_container.sh
```

The script fetches the latest signed `apple/container` package, stops the
services, replaces `$HOME/usr/local/bin` + `libexec/container`, starts the
services, and prints `container system version`. After it succeeds, run:

```sh
script/verify_apple_container_1_5.sh
```

It checks the version is at least 1.5.0 and runs
`smoke_xpc_extra` (copy-in, volume mount, masked/readonly paths, SSH,
custom kernel), then cleans the test volume and prints the container
list. The update was applied on 2026-10-17 and this script passed; the
0.12.3 results remain historical and are not used as 1.5.0 PASS evidence.
Note: on this user-local install, `container system status` still reports
"not running and not registered" while `container list`/`image list` and
the XPC service work; record that quirk rather than treating it as a
failed service.
