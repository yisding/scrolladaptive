#!/bin/sh
# Builds scrolladaptive and runs it at login as a LaunchAgent.
#
#   ./install.sh            install or update
#   ./install.sh uninstall  stop and remove
#
# Run this inside the macOS guest.

set -eu

label=local.scrolladaptive
source_dir=$(cd "$(dirname "$0")" && pwd)
install_dir="$HOME/Library/Application Support/scrolladaptive"
binary="$install_dir/scrolladaptive"
plist="$HOME/Library/LaunchAgents/$label.plist"
log="$HOME/Library/Logs/scrolladaptive.log"
domain="gui/$(id -u)"

stop_agent() {
  launchctl bootout "$domain/$label" 2>/dev/null || true
}

if [ "${1:-}" = uninstall ]; then
  stop_agent
  rm -f "$plist"
  rm -rf "$install_dir"
  echo "Removed scrolladaptive. You can also remove it from System Settings >"
  echo "Privacy & Security > Accessibility."
  exit 0
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Command Line Tools with: xcode-select --install" >&2
  exit 1
fi

mkdir -p "$source_dir/build"
swiftc -O -target arm64-apple-macosx13.0 "$source_dir/scrolladaptive.swift" \
  -o "$source_dir/build/scrolladaptive"

stop_agent
mkdir -p "$install_dir" "$(dirname "$plist")" "$(dirname "$log")"

# Accessibility permission is tied to the binary's signature, so only replace
# the binary when it changed. Otherwise you'd have to grant permission again.
if cmp -s "$source_dir/build/scrolladaptive" "$binary"; then
  echo "Binary unchanged."
else
  if [ -f "$binary" ]; then
    echo "Binary changed. You'll need to grant Accessibility permission again: remove"
    echo "scrolladaptive from System Settings > Privacy & Security > Accessibility,"
    echo "then allow it when prompted."
  fi
  cp "$source_dir/build/scrolladaptive" "$binary"
fi

cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$binary</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardErrorPath</key>
  <string>$log</string>
</dict>
</plist>
EOF

launchctl bootstrap "$domain" "$plist"

echo "Installed. scrolladaptive now starts at login."
echo "If macOS asks, allow it in System Settings > Privacy & Security > Accessibility."
echo "Log: $log"
