#!/bin/bash
set -euo pipefail
signing_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
expected_certificate_sha256='@SIGNING_SHA256@'
if [[ ! "$expected_certificate_sha256" =~ ^[0-9a-f]{64}$ ]]; then
  fingerprint_file="$signing_directory/../Sources/TerminalMacCore/Signing/SigningFingerprint.txt"
  [[ -f "$fingerprint_file" ]] || { echo 'Signing is not configured. Run scripts/configure-signing.sh before building.' >&2; exit 1; }
  expected_certificate_sha256="$(< "$fingerprint_file")"
fi
[[ "$expected_certificate_sha256" =~ ^[0-9a-f]{64}$ ]] || { echo 'Invalid signing fingerprint.' >&2; exit 1; }

verify_app_signature() {
  local app="$1" identifier="$2" work certificate_sha256
  codesign --verify --deep --strict -R="identifier \"$identifier\"" "$app" || return 1
  work="$(mktemp -d "${TMPDIR:-/tmp}/terminal-mac-signature.XXXXXX")" || return 1
  if ! codesign --display --extract-certificates="$work/certificate-" "$app" >/dev/null 2>&1 || [[ ! -f "$work/certificate-0" ]]; then
    rm -rf "$work"
    echo "App was not signed with the pinned certificate: $app" >&2
    return 1
  fi
  certificate_sha256="$(shasum -a 256 "$work/certificate-0")" || { rm -rf "$work"; return 1; }
  rm -rf "$work"
  [[ "${certificate_sha256%% *}" = "$expected_certificate_sha256" ]] || { echo "App was not signed with the pinned certificate: $app" >&2; return 1; }
}

verify_package_signature() {
  verify_app_signature "$1" dev.terminal-mac.host &&
    verify_app_signature "$1/Contents/Resources/guest-tools/TerminalMacGuest.app" dev.terminal-mac.guest
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
  [[ $# -eq 1 ]] || { echo 'Usage: bash verify-signature.sh TerminalMac.app' >&2; exit 1; }
  verify_package_signature "$1"
fi