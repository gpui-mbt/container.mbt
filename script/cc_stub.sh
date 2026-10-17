#!/bin/sh
# Compile native stubs with blocks support only on Apple platforms.
# XPC uses block handlers; Linux has no XPC headers and the XPC stub is
# #ifdef'd to no-op stubs there, so -fblocks must not leak to Linux cc.
if [ "$(uname -s)" = "Darwin" ]; then
  exec "${CC:-cc}" -fblocks "$@"
else
  exec "${CC:-cc}" "$@"
fi
