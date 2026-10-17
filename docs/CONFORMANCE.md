# Conformance oracle (issue 0050)

Oracle: `shiguredo/container-rs@f68ba1ffed67c9c4e9abdb39212835d50d7afcf3`
(develop, 2026-10-07). MoonBit revision: the commit containing this file.
Never treat "upstream source has a function" as parity evidence; run the
fixture and record the observable result.

## Fixture format

Each fixture records:

| Field | Meaning |
|---|---|
| ID | Stable fixture name |
| Input | image, cmd, env, ports, waits, timeout |
| Upstream operation | upstream test name or exact command |
| MoonBit operation | smoke/test name and command |
| Observations | exit code, stdout/stderr, published ports, file contents, elapsed/error |
| Expectation | observable result, not internal type equality |
| Upstream result | PASS / FAIL / 未実行 |
| MoonBit result | PASS / FAIL / 未実行 |
| Environment | OS, arch, Docker/Apple container version, revisions |
| Verdict | PASS / FAIL / 未実行 / documented deviation |

A documented deviation is not a PASS; it must state the reason and a
re-evaluation trigger.

## Current fixture table

Environment: physical Apple Silicon, macOS 26.5.2, Apple Container 1.5.0,
MoonBit 0.1.20261012. Linux Docker daemon was not running; its fixtures
are 未実行. The earlier 0.12.3 run is historical and not used for 1.5.0
PASS evidence.

| ID | Input | Upstream | MoonBit | Observations | Upstream | MoonBit | Verdict |
|---|---|---|---|---|---|---|---|
| exit | `sh -c "printf out; printf err 1>&2; exit 3"` | `cargo test` exit fixture (not run) | `smoke_xpc` exec step | exit 3, stdout `out`, stderr `err` | 未実行 | PASS | MoonBit PASS; upstream 未実行 |
| logs | init prints `xpc-ready`, then ticks `xpc-tick` | macOS log fixture (not run) | `smoke_xpc` logs + subscription | `xpc-ready` in one-shot logs; `xpc-tick` delivered by `subscribe_logs` | 未実行 | PASS | MoonBit PASS; upstream 未実行 |
| ports | `with_mapped_port(0, tcp 80)` + host `GET /` | macOS port fixture (not run) | `smoke_xpc` TCP step | host port resolved (e.g. 52032), `200 OK` + `moonbit-xpc-tcp` | 未実行 | PASS | MoonBit PASS; upstream 未実行 |
| copy | `with_copy_to("/copied", Data("copy-data"))` | macOS copy fixture (not run) | `smoke_xpc_extra` | read back `copy-data` | 未実行 | PASS | MoonBit PASS; upstream 未実行 |
| timeout | `containerWait` on a missing process | macOS timeout fixture (not run) | `xpc_bridge_wbtest` timeout | bounded timeout, late-reply cleanup | 未実行 | PASS | MoonBit PASS; upstream 未実行 |
| volume | volume mount `/vol` | macOS volume fixture (not run) | `smoke_xpc_extra` | write/read `/vol/x` = `v` | 未実行 | PASS | MoonBit PASS; upstream 未実行 |
| masked | `with_masked_paths(["/etc/passwd"])` | macOS masked fixture (not run) | `smoke_xpc_extra` | `/etc/passwd` unreadable | 未実行 | PASS | MoonBit PASS; upstream 未実行 |
| readonly | `with_readonly_paths(["/etc/hosts"])` | macOS readonly fixture (not run) | `smoke_xpc_extra` | write rejected | 未実行 | PASS | MoonBit PASS; upstream 未実行 |
| kernel | custom vmlinux | macOS kernel fixture (not run) | `smoke_xpc_extra` | container starts with custom kernel | 未実行 | PASS | MoonBit PASS; upstream 未実行 |
| linux-exit | `sh -c "exit 3"` on Docker | `cargo test --test container_linux` | `smoke_linux` | no Docker daemon on this host | 未実行 | 未実行 | 未実行 (environment) |

## How to extend

1. Add a row with all columns filled (use 未実行 rather than guessing).
2. Run the upstream fixture from a pinned checkout (`cargo test <name>`)
   and the MoonBit smoke; paste the command and raw output.
3. If the difference is intentional (e.g. MoonBit's 64 MiB exec bound),
   label it `documented deviation` with the issue number and a trigger
   for re-evaluation.
4. Keep one upstream revision per fixture. A revision update is a separate
   change and must update [UPSTREAM_DRIFT.md](UPSTREAM_DRIFT.md) and the
   fixture's revision column together.
