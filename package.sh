#!/bin/bash
# Build JevBar.app: a signed, self-contained menu-bar application.
#
# Signed with a stable identity from the very first build. macOS ties
# Accessibility and Keychain grants to an application's designated requirement,
# and an ad-hoc signature has no stable identity for one — so the requirement
# degrades to a hash of the binary and every rebuild silently revokes the grant
# while the toggle in System Settings still reads "on". JevDesk lost most of a
# day to that twice.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/JevBar.app"
IDENTITY="JevBar Local Signing"

swift build -c release --product JevBar

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/JevBar" "$APP/Contents/MacOS/JevBar"

# The engine travels inside the bundle. Never referenced by a path built from
# the working directory, which is the filesystem root once this is launched
# from Finder.
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
</dict></plist>
PLIST

# Extended attributes come along with a filesystem copy and codesign refuses a
# bundle carrying them. A synced folder re-attaches them asynchronously, so the
# copy is made without them rather than stripped afterwards, which is a race.
xattr -cr "$APP" 2>/dev/null || true

# The engine is signed on its own, before the bundle.
#
# `--deep` does not reach it. It re-signs recognised nested *code* — frameworks,
# embedded app bundles — and a plain executable under Resources/ is resource
# data as far as codesign is concerned. That matters because the engine is a
# separate process with its own signature, and it is the one that asks for
# Accessibility: signing only the app fixes the requirement for the process that
# does not need the permission and leaves it broken for the one that does.
sign_all() {
  local id="$1"
  if [ -f "$APP/Contents/Resources/munim-computer-use" ]; then
    codesign --force --sign "$id" "$APP/Contents/Resources/munim-computer-use"
  fi
  # Signing the engine writes extended attributes back onto the bundle, and
  # codesign refuses one that carries them ("resource fork, Finder information,
  # or similar detritus"). Clearing before the outer signature rather than only
  # before the inner one is the difference between a build and a puzzle.
  xattr -cr "$APP" 2>/dev/null || true
  codesign --force --deep --sign "$id" "$APP"
}

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  sign_all "$IDENTITY"
  echo "  signed with '$IDENTITY' — permissions will survive rebuilds"
else
  sign_all -
  echo "  ! signed ad-hoc. macOS will forget Accessibility on every rebuild."
  echo "    Run ./signing-identity.sh once to fix that."
fi

echo
echo "JevBar.app is in $ROOT/dist"
