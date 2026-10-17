#!/bin/bash
# Run the 1.5.0+ Apple Container extra acceptance (copy-in, volume,
# masked/readonly paths, custom kernel). Run after
# script/update_apple_container.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTAINER="${HOME}/usr/local/bin/container"
VOLUME="container-mbt-xpc-extra-vol"

[ -x "$CONTAINER" ] || { echo "missing $CONTAINER" >&2; exit 1; }
VERSION="$("$CONTAINER" --version | awk '{print $4}' | tr -d ')')"
python3 - "$VERSION" <<'PY'
import sys
def parts(v):
    return tuple(int(x) for x in v.split('.')[:3])
if parts(sys.argv[1]) < (1, 5, 0):
    raise SystemExit(f"Apple Container {sys.argv[1]} is older than 1.5.0")
PY

cd "$ROOT"
moon build --target native
"$CONTAINER" volume delete "$VOLUME" >/dev/null 2>&1 || true
env -i HOME="$HOME" PATH=/usr/bin:/bin \
  "$ROOT/_build/native/debug/build/smoke_xpc_extra/smoke_xpc_extra.exe"
"$CONTAINER" volume delete "$VOLUME" >/dev/null 2>&1 || true
echo "--- containers after ---"
"$CONTAINER" list --all
