#!/bin/bash
set -euo pipefail
umask 077
[[ $# -eq 1 ]] || { echo 'Usage: bash scripts/test-package.sh /absolute/path/to/release.zip' >&2; exit 1; }
archive="$1"
work="$(mktemp -d "${TMPDIR:-/tmp}/terminal-mac-package-test.XXXXXX")"
test_keychain=""
cleanup() {
  if [[ -n "$test_keychain" ]]; then security delete-keychain "$test_keychain" >/dev/null 2>&1 || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
ditto -x -k "$archive" "$work/unpacked"
installer="$(find "$work/unpacked" -name install.sh -type f | head -1)"
[[ -n "$installer" ]] || { echo 'Release installer is missing.' >&2; exit 1; }
prefix="$work/prefix with spaces"
bash "$installer" --prefix "$prefix"
bash "$installer" --prefix "$prefix"
launcher="$prefix/bin/terminal-mac"
# The version must come from the installed bundle, not a fallback.
expected="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(dirname "$installer")/TerminalMac.app/Contents/Info.plist")"
[[ "$("$launcher" --version)" == "terminal-mac $expected" ]] || { echo "Version mismatch: $("$launcher" --version), expected $expected" >&2; exit 1; }
TERMINAL_MAC_HOME="$work/unused-data" "$launcher" up test --plan > "$work/plan.json"
[[ ! -e "$work/unused-data" ]] || { echo 'Plan unexpectedly created VM data.' >&2; exit 1; }
python3 - "$work/plan.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
assert plan['name'] == 'test'
assert plan['steps'][0] == 'download-or-reuse-apple-restore-image'
PY
# The guard refuses physical Macs. CI runners are themselves virtual Macs, where it must allow.
if [[ "$(sysctl -n hw.model)" == VirtualMac* ]]; then
  "$launcher" guest --check | grep -q '^virtual-mac$' || { echo 'Guest guard rejected a virtual Mac.' >&2; exit 1; }
else
  if "$launcher" guest --check > "$work/guard.log" 2>&1; then echo 'Guest guard unexpectedly allowed the physical host.' >&2; exit 1; fi
  grep -q 'only runs inside a virtual Mac' "$work/guard.log"
fi
TERMINAL_MAC_HOME="$work/unused-data" "$launcher" skills get | grep -q '^name: terminal-mac$'
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | TERMINAL_MAC_HOME="$work/unused-data" "$launcher" mcp | grep -q '"screenshot"'
if "$launcher" up ../escape --plan > "$work/name.log" 2>&1; then echo 'Invalid machine name was accepted.' >&2; exit 1; fi
conflict="$work/conflict"
mkdir -p "$conflict/bin"
echo 'preserve me' > "$conflict/bin/terminal-mac"
if bash "$installer" --prefix "$conflict" > "$work/conflict.log" 2>&1; then echo 'Unrelated executable was overwritten.' >&2; exit 1; fi
[[ "$(cat "$conflict/bin/terminal-mac")" = 'preserve me' ]]
package="$(dirname "$installer")"
if find "$package" -name '*.cer' -type f | grep -q .; then echo 'Package unexpectedly includes a standalone certificate.' >&2; exit 1; fi
if grep -q '@SIGNING_SHA256@' "$package/verify-signature.sh"; then echo 'Installer fingerprint was not rendered.' >&2; exit 1; fi
bash "$package/verify-signature.sh" "$package/TerminalMac.app"
original_link="$(readlink "$launcher")"
original_hash="$(shasum -a 256 "$launcher")"
reject_package() {
  local candidate="$1"
  if bash "$candidate/install.sh" --prefix "$prefix" > "$work/rejection.log" 2>&1; then
    echo "Untrusted package was accepted: $candidate" >&2; exit 1
  fi
  [[ "$(readlink "$launcher")" = "$original_link" && "$(shasum -a 256 "$launcher")" = "$original_hash" ]] || {
    echo 'Rejected installation changed the existing launcher or executable.' >&2; exit 1
  }
}
ditto "$package" "$work/unsigned"
codesign --remove-signature "$work/unsigned/TerminalMac.app"
reject_package "$work/unsigned"
ditto "$package" "$work/ad-hoc"
codesign --force --sign - --timestamp=none "$work/ad-hoc/TerminalMac.app" >/dev/null 2>&1
reject_package "$work/ad-hoc"
ditto "$package" "$work/tampered"
printf '\n' >> "$work/tampered/TerminalMac.app/Contents/Info.plist"
reject_package "$work/tampered"
password="$(openssl rand -hex 16)"
test_keychain="$work/foreign.keychain-db"
security create-keychain -p "$password" "$test_keychain"
security unlock-keychain -p "$password" "$test_keychain"
printf '%s\n' '[req]' 'distinguished_name = dn' 'x509_extensions = ext' 'prompt = no' '[dn]' \
  'CN = TerminalMac Fork Code Signing' '[ext]' 'basicConstraints = critical, CA:false' \
  'keyUsage = critical, digitalSignature' 'extendedKeyUsage = critical, codeSigning' > "$work/foreign.cnf"
openssl req -x509 -newkey rsa:2048 -sha256 -days 1 -nodes -config "$work/foreign.cnf" \
  -keyout "$work/foreign.key" -out "$work/foreign.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$work/foreign.key" -in "$work/foreign.pem" -out "$work/foreign.p12" \
  -passout "pass:$password" -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
security import "$work/foreign.p12" -k "$test_keychain" -P "$password" -T /usr/bin/codesign >/dev/null
foreign_hash="$(openssl x509 -in "$work/foreign.pem" -outform DER | shasum -a 1)"; foreign_hash="${foreign_hash%% *}"
ditto "$package" "$work/foreign"
codesign --force --deep --sign "$foreign_hash" --keychain "$test_keychain" --timestamp=none "$work/foreign/TerminalMac.app" >/dev/null 2>&1
codesign --verify --deep --strict "$work/foreign/TerminalMac.app"
reject_package "$work/foreign"
if [[ -n "${TERMINAL_MAC_TEST_SIGNING_IDENTITY:-}" ]]; then
  ditto "$package" "$work/foreign-guest"
  foreign_fingerprint="$(openssl x509 -in "$work/foreign.pem" -outform DER | shasum -a 256)"
  printf '%s\n' "${foreign_fingerprint%% *}" > "$work/foreign-guest/TerminalMac.app/Contents/Resources/guest-tools/TerminalMacGuest.app/Contents/Resources/terminal-mac_TerminalMacCore.bundle/Signing/SigningFingerprint.txt"
  codesign --force --sign "$foreign_hash" --keychain "$test_keychain" --timestamp=none \
    "$work/foreign-guest/TerminalMac.app/Contents/Resources/guest-tools/TerminalMacGuest.app" >/dev/null 2>&1
  codesign --force --sign "$TERMINAL_MAC_TEST_SIGNING_IDENTITY" --preserve-metadata=entitlements --timestamp=none \
    "$work/foreign-guest/TerminalMac.app" >/dev/null 2>&1
  codesign --verify --deep --strict "$work/foreign-guest/TerminalMac.app"
  reject_package "$work/foreign-guest"
else
  echo 'Nested foreign-signer test skipped: set TERMINAL_MAC_TEST_SIGNING_IDENTITY to the pinned identity.'
fi
echo 'Package checks passed: installation, paths, plan, host guard, MCP, unsigned/ad-hoc/tampered/foreign signatures rejected without replacing the launcher.'
