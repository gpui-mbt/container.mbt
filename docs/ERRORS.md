# Failure classification and redaction (issue 0049)

`failure.mbt` adds a public, additive view over adapter errors. Existing
`raise` effects and messages are unchanged, so `catch { _ => ... }`
callers keep working. Use `classify_failure(error) -> FailureKind` when a
caller needs to branch.

## Vocabulary

`FailureKind` = `Client(ClientFailure)` / `WaitContainer` /
`PortNotExposed` / `Exec` / `Io` / `Other`.

`ClientFailure` = `Connect` / `Protocol` / `Timeout` /
`Authentication` / `ImageNotFound` / `ContainerNotFound` /
`ContainerPathNotFound` / `Configuration` / `Json` / `Other`.

## Mapping table

| Cause | Docker Engine (`EngineError`) | Apple XPC (`XpcError`) | CLI fallback |
|---|---|---|---|
| daemon/socket down | `TransportError` → `Connect` | `Connect`/`NotApple` → `Connect` | message contains socket/refused → `Connect` |
| deadline | `DeadlineExceeded` → `Timeout` | `Timeout` → `Timeout` | message contains timeout/deadline → `Timeout` |
| image absent | `ImageNotFound` → `ImageNotFound` | `Remote` with image/not found → `ImageNotFound` | message heuristics |
| container absent | `ContainerNotFound` → `ContainerNotFound` | `Remote` with container/not found → `ContainerNotFound` | message heuristics |
| in-container path absent | `ContainerPathNotFound` → `ContainerPathNotFound` | `Remote` with path/not found → `ContainerPathNotFound` | message heuristics |
| auth failure | `Unauthorized`/`Forbidden` → `Authentication` | `Remote` 401/403/denied → `Authentication` | message heuristics |
| malformed framing | `MalformedResponse` → `Protocol` | `Malformed`/`MissingKey`/`TypeMismatch`/`NonUtf8` → `Protocol` | `Json`/decode → `Json` or `Protocol` |
| config/preflight | `ApiVersionTooOld` → `Configuration` | `NotApple` is connect; preflight errors are plain messages → `Other` | plain messages |

## Redaction

`redact_secret(text)` removes the value after
`x-registry-auth:`, `authorization:`, `password=`, `token=`, and
`secret=`. Authorization headers are redacted to end of line; key/value
forms stop at whitespace, quotes, or commas. The Engine adapter never
puts `X-Registry-Auth` into an error message; CLI stderr is opaque, so
callers logging it should run it through `redact_secret` first.

## Cleanup

Cleanup failure must not replace the original failure. `with_container`,
`start` rollback, and the XPC errdefer paths append a diagnostic note but
preserve the original error/classification. `classify_failure` only
inspects the returned error, not cleanup notes.
