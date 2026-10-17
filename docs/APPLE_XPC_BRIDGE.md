# Apple Container XPC bridge

This document is the ownership/ABI contract for the MoonBit-native Apple
Container path (issues 0023/0024). It complements
[APPLE_E2E.md](APPLE_E2E.md) and [PORTING.md](PORTING.md).

## Services and routes

- Container service: `com.apple.container.apiserver`
- Image service: `com.apple.container.core.container-core-images`
- Route key: `com.apple.container.xpc.route`
- Remote error key: `com.apple.container.xpc.error`
- Default timeout: 60 s; `containerWait`/`imagePull`: 24 h.

Used routes: `containerList`, `containerCreate`, `containerBootstrap`,
`containerStartProcess`, `containerCreateProcess`, `containerWait`,
`containerStop`, `containerDelete`, `containerLogs`, `containerCopyIn`,
`containerCopyOut`, `volumeCreate`, `volumeInspect`, `imagePull`,
`imageList`, `contentGet`, `getDefaultKernel`.

## Async model

The MoonBit async runtime is single-threaded and has no `spawn_blocking`.
A blocking XPC wait would freeze unrelated tasks, so the bridge splits a
call into:

1. `moonbit_xpc_send_async` — build the dictionary and register a reply
   block that stores a retained reply in an atomic context.
2. `moonbit_xpc_poll` — MoonBit polls the context and `@async.sleep(1)`
   between checks.
3. `moonbit_xpc_take_reply` — transfers the retained reply.
4. `moonbit_xpc_abandon` — on timeout/cancel; a late reply is released by
   the reply block, never by the waiter.

The context uses an atomic state (`pending` / `ready` / `abandoned` /
`taken`) and a two-reference lifetime (waiter + reply block). This is the
same late-reply safety property as upstream's atomic refcount, without
blocking the event loop.

## Ownership

| Handle | Owner | Release |
|---|---|---|
| `XpcConnectionPtr` | `XpcConnection` wrapper | cancel + release, always via `defer` |
| `XpcMessagePtr` | `XpcMessage` wrapper | release, always via `defer` |
| `XpcContextPtr` | `send` caller | take or abandon exactly once |
| `XpcReplyPtr` | `XpcReply` wrapper | `close()`, always via `defer` |
| log FD | caller of `XpcReply::log_fds` | close both; invalid sets close valid ones |
| copy-in FD write ends | exec caller | close after `containerCreateProcess` |
| exec stdout/stderr pipes | `exec_process` | `RawFdStream::close` |

All C → MoonBit strings/data are copied into GC-managed `Bytes`; no raw
pointer escapes. All non-primitive parameters are `#borrow` or owned by
the wrapper. A failed call must not leave a connection, message, context,
or reply behind.

## Stub portability

`xpc_stub.c` contains the real implementation only under `__APPLE__`.
Other natives compile stubs returning `ENOTSUP`/null; `is_apple()` gates
the MoonBit path so Linux builds stay clean. `script/cc_stub.sh` adds
`-fblocks` only on Darwin. The package's `native-stub` list contains both
`unix_transport.c` and `xpc_stub.c`.

## Error model

`XpcError` distinguishes `NotApple`, `Connect`, `Timeout`, `Closed`,
`Remote {code,message}`, `Malformed`, `NonUtf8`, `MissingKey`, and
`TypeMismatch`. `XpcReply` checks the XPC type before copying (string,
data, int64, uint64, bool, array); a missing key and a wrong-type key are
different errors. Remote JSON errors are formatted as
`XPC error {code}: {message}`; non-UTF-8 and unparseable payloads are
kept distinct.

## Version boundary (measured)

The acceptance host was updated from Apple Container **0.12.3** to
**1.5.0** on 2026-10-17.

- 1.5.0 verified: pull/resolve, create/bootstrap/start, exec, logs and
  live subscription, stop/rm, dynamic ports, bridge/gateway,
  bind/tmpfs/volume mounts, post-start copy-in (File and Data), masked
  paths, read-only paths, `with_ssh()`, and a custom kernel.
- `containerStop` on 0.12.3 decoded `signal` as an Int32; the bridge sends
  15/9 and retries the string form once if the server explicitly rejects
  the signal field. 1.5.0 accepts the numeric form used here.
- Volume config uses `cache: {"on":{}}` (the 1.5.0 CLI's shape). The
  pinned upstream Rust source used `auto`; 1.5.0 was re-verified after
  this change.
- Historical 0.12.3: `containerCopyIn` returned **Connection interrupted**
  and masked/readonly/volume live E2E could not run. This was confirmed
  to be an apiserver-side gap by running the 1.5.0 CLI `container cp`
  against the 0.12.3 apiserver (same error). Those historical results are
  not PASS evidence for the current version.
