#!/usr/bin/env bash
# Register the virtual-headset-bridge native-messaging host with Firefox.
#
# For non-Nix setups. Nix/Home-Manager users should use the
# `programs.virtual-headset-firefox` module instead.
#
# Usage: ./install-native-host.sh [/path/to/virtual-headset-bridge]
set -euo pipefail

bridge="${1:-$(command -v virtual-headset-bridge || true)}"
if [[ -z "$bridge" || ! -x "$bridge" ]]; then
  echo "error: could not find the virtual-headset-bridge binary." >&2
  echo "Build it with: cargo build --release --manifest-path packages/virtual-headset/Cargo.toml" >&2
  echo "Then pass its path: $0 packages/virtual-headset/target/release/virtual-headset-bridge" >&2
  exit 1
fi
bridge="$(realpath "$bridge")"

dest="$HOME/.mozilla/native-messaging-hosts"
mkdir -p "$dest"
cat >"$dest/virtual_headset_bridge.json" <<EOF
{
  "name": "virtual_headset_bridge",
  "description": "Virtual Headset D-Bus bridge for the Firefox extension",
  "path": "$bridge",
  "type": "stdio",
  "allowed_extensions": ["virtual-headset@local"]
}
EOF

echo "Installed native-messaging host manifest:"
echo "  $dest/virtual_headset_bridge.json"
echo "  -> $bridge"
echo
echo "Next: build the extension (cd extension && npm install && npm run build),"
echo "then load extension/dist/manifest.json via"
echo "about:debugging -> This Firefox -> Load Temporary Add-on."
