#!/bin/bash
# Update the user-local Apple Container installation to the latest release.
#
# This must be run from a normal Terminal (outside the agent sandbox),
# because it writes under $HOME/usr/local and restarts launchd services.
# The prefix is the existing user-local install, not /usr/local.
set -euo pipefail

PREFIX="${HOME}/usr/local"
INSTALL_DIR="${PREFIX}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Fetching latest Apple Container release..."
RELEASE_JSON="$(curl -fsSL https://api.github.com/repos/apple/container/releases/latest)"
VERSION="$(printf '%s' "$RELEASE_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["tag_name"])')"
PKG_URL="$(printf '%s' "$RELEASE_JSON" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for a in d["assets"]:
    if a["name"].endswith("installer-signed.pkg"):
        print(a["browser_download_url"])
        break
')"
[ -n "$PKG_URL" ] || { echo "no signed installer asset found" >&2; exit 1; }

echo "Installing Apple Container ${VERSION} from ${PKG_URL}"
curl -fSL "$PKG_URL" -o "$TMP_DIR/container.pkg"
pkgutil --expand-full "$TMP_DIR/container.pkg" "$TMP_DIR/expanded"

echo "Stopping Apple Container services..."
"$PREFIX/bin/container" system stop >/dev/null 2>&1 || true
sleep 1

echo "Copying payload to ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/libexec"
cp -f "$TMP_DIR/expanded/Payload/bin/container" "$INSTALL_DIR/bin/container"
cp -f "$TMP_DIR/expanded/Payload/bin/container-apiserver" "$INSTALL_DIR/bin/container-apiserver"
cp -f "$TMP_DIR/expanded/Payload/bin/update-container.sh" "$INSTALL_DIR/bin/update-container.sh"
cp -f "$TMP_DIR/expanded/Payload/bin/uninstall-container.sh" "$INSTALL_DIR/bin/uninstall-container.sh"
rm -rf "$INSTALL_DIR/libexec/container"
cp -R "$TMP_DIR/expanded/Payload/libexec/container" "$INSTALL_DIR/libexec/container"
chmod +x "$INSTALL_DIR/bin/container" "$INSTALL_DIR/bin/container-apiserver"

echo "Starting services..."
"$PREFIX/bin/container" system start
"$PREFIX/bin/container" system version

echo "Done. Verify with:"
echo "  $PREFIX/bin/container --version"
echo "  $PREFIX/bin/container image list"
