#!/bin/bash
# Create JevBar's local code-signing certificate. Once per machine.
#
# Not for Gatekeeper — for TCC, the database behind the Accessibility and
# Screen Recording toggles. It records a grant against the application's
# designated requirement, and an ad-hoc signature has no stable identity to
# build one from, so the requirement becomes a hash of the binary and every
# rebuild quietly revokes the grant.
#
# Self-signed is the right scope: a paid developer account buys distribution to
# other people's machines, which is a different problem from keeping a
# permission on your own.
set -euo pipefail

IDENTITY="JevBar Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "'$IDENTITY' already exists. Nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -nodes -subj "/CN=$IDENTITY" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" 2>/dev/null

# -legacy: OpenSSL 3 defaults to a scheme the macOS keychain will not import,
# and it fails with "MAC verification failed (wrong password?)" — which sends
# you looking at the password instead of the cipher.
openssl pkcs12 -export -legacy -out "$WORK/bundle.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -passout pass:jevbar -name "$IDENTITY" 2>/dev/null

security import "$WORK/bundle.p12" -k "$KEYCHAIN" -P jevbar -T /usr/bin/codesign

# Importing is not enough: an untrusted certificate is not a *valid* identity
# and codesign will not use it. User-domain trust needs no administrator.
security add-trusted-cert -r trustRoot -k "$KEYCHAIN" "$WORK/cert.pem"

security find-identity -v -p codesigning | grep -q "$IDENTITY" \
  || { echo "created, but not a valid signing identity" >&2; exit 1; }

echo "Created '$IDENTITY'. Run ./package.sh, then grant JevBar Accessibility once."
