#!/bin/bash
# Build, sign and install JevBar.app, then restart it.
#
# ## Why it is assembled outside the repository
#
# This checkout is on the Desktop, which is FileProvider-synced, and the sync
# daemon re-attaches `com.apple.FinderInfo` to anything that appears there —
# asynchronously, so clearing extended attributes and then signing is a race
# rather than a sequence. Retrying narrows it; staging where nothing watches
# removes it. The bundle is signed in a temporary directory and only then
# carried to its home.
#
# ## Why it installs to ~/Applications
#
# macOS ties an Accessibility grant to the application's signature *and* its
# path. A stable path plus a stable signing identity is what lets a rebuild
# inherit the permission you already gave, instead of asking again every time.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
STAGE="$(mktemp -d)"
APP="$STAGE/JevBar.app"
INSTALLED="$HOME/Applications/JevBar.app"
IDENTITY="JevBar Local Signing"
trap 'rm -rf "$STAGE"' EXIT

swift build -c release --product JevBar

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/JevBar" "$APP/Contents/MacOS/JevBar"

ENGINE="${JEVBAR_ENGINE:-$ROOT/../JevDesk/native/cua/.build/munim-computer-use}"
if [ -f "$ENGINE" ]; then
  cp "$ENGINE" "$APP/Contents/Resources/munim-computer-use"
else
  echo "  ! computer-use engine not found at $ENGINE — JevBar will say so on launch"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>JevBar</string>
  <key>CFBundleDisplayName</key><string>JevBar</string>
  <key>CFBundleIdentifier</key><string>com.jevbar.app</string>
  <key>CFBundleExecutable</key><string>JevBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>JevBar listens only while you hold its shortcut.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>JevBar turns what you say into a command, on this Mac.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>JevBar opens and closes the applications you name.</string>
</dict></plist>
PLIST

# Everything that goes into the bundle is written before signing. Writing a
# single byte afterwards breaks the seal, and macOS refuses an invalid
# signature's permissions — which looks exactly like a permission that was
# never granted.
sign_all() {
  local id="$1"
  if [ -f "$APP/Contents/Resources/munim-computer-use" ]; then
    # `--deep` does not reach a plain executable under Resources/, and the
    # engine is the process that asks for Accessibility — so signing only the
    # app fixes the identity of the process that does not need the permission.
    codesign --force --sign "$id" "$APP/Contents/Resources/munim-computer-use"
  fi
  codesign --force --deep --sign "$id" "$APP"
}

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  sign_all "$IDENTITY"
else
  sign_all -
  echo "  ! signed ad-hoc. macOS will forget Accessibility on every rebuild."
  echo "    Run ./signing-identity.sh once to fix that."
fi

codesign -v --deep --strict "$APP"

# The running copy is replaced, so it is asked to quit first — a bundle
# swapped underneath a live process is a process running code that no longer
# exists on disk.
pkill -f "$INSTALLED/Contents/MacOS/JevBar" 2>/dev/null || true
sleep 1

rm -rf "$INSTALLED"
mkdir -p "$HOME/Applications"
ditto --noextattr --norsrc --noacl "$APP" "$INSTALLED"

if [ "${JEVBAR_NO_LAUNCH:-}" != "1" ]; then
  open "$INSTALLED"
  echo "JevBar restarted — $INSTALLED"
else
  echo "JevBar installed — $INSTALLED"
fi
