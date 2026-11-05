#!/bin/bash
# Creates a self-signed code-signing identity in your login keychain using the release configuration.
#   bash scripts/create-signing-identity.sh ["Certificate Name"]
# Releases signed with it carry no personal name, and macOS keeps the guest helper's Screen Recording
# and Accessibility approvals across updates because the signing certificate stays the same.
# Back it up (Keychain Access → My Certificates → Export) to sign future releases on another Mac:
# a new certificate makes every user approve the guest permissions once more.
set -euo pipefail
source "$(dirname "$0")/release-config.sh"
name="${1:-$SIGNING_NAME}"
if security find-identity -p codesigning | grep -qF "\"$name\""; then
  echo "\"$name\" already exists in your keychain."; exit 0
fi
if [[ -f "$(dirname "$0")/../Sources/TerminalMacCore/Signing/SigningFingerprint.txt" ]]; then
  echo 'A signing fingerprint is already configured. Restore its private key from your backup; creating another certificate will not match.' >&2
  exit 1
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/signing-identity.XXXXXX")"
# The private key only ever exists here and in the keychain.
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"
cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes -config "$work/cert.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
password="$(openssl rand -hex 16)"
# macOS imports only the older PKCS#12 encryption, not OpenSSL 3's AES default.
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" -out "$work/identity.p12" \
  -passout "pass:$password" -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
# -T lets codesign use the key without a keychain prompt on every build.
security import "$work/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$password" -T /usr/bin/codesign >/dev/null
security find-identity -p codesigning | grep -F "\"$name\"" >/dev/null || { echo 'Import failed.' >&2; exit 1; }
echo "Created \"$name\" (valid until $(date -v+10y +%Y-%m-%d)). It is self-signed, so macOS lists it as not trusted; codesign still uses it."
