#!/bin/bash
# Build the computer-use engine JevBar launches, from pinned upstream source.
#
# munim-computer-use (Apache 2.0) is not vendored here. It is cloned at a fixed
# tag and checked against a fixed commit, because a program that controls the
# desktop is a high-trust dependency and should not change underneath you.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="$ROOT/.build/engine/munim-computer-use"
TAG="v0.4.1"
REVISION="4d2ae8fbac526191d02ab4072ad730a0438cffde"

if [ -x "$OUTPUT" ]; then
  exit 0
fi

echo "Building the computer-use engine ($TAG). This happens once."
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

git clone --quiet --depth 1 --branch "$TAG" \
  https://github.com/munimtechnologies/munim-computer-use.git "$SCRATCH/src"
ACTUAL="$(git -C "$SCRATCH/src" rev-parse HEAD)"
if [ "$ACTUAL" != "$REVISION" ]; then
  echo "Engine source changed: expected $REVISION, got $ACTUAL" >&2
  exit 1
fi

(cd "$SCRATCH/src/macos" && swift build -c release)
mkdir -p "$(dirname "$OUTPUT")"
cp "$SCRATCH/src/macos/.build/release/munim-computer-use" "$OUTPUT"
chmod 755 "$OUTPUT"
echo "Engine built at $OUTPUT"
