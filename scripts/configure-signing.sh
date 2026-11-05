#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/release-config.sh
rotate=false
case "${1:-}" in
  --rotate) rotate=true; shift ;;
  --help|-h) echo 'Usage: [SIGN_IDENTITY=IDENTITY] bash scripts/configure-signing.sh [--rotate]'; exit 0 ;;
esac
[[ $# -eq 0 ]] || { echo 'Unexpected arguments. Use --help.' >&2; exit 1; }
identity="${SIGN_IDENTITY:-$SIGNING_NAME}"
[[ "$identity" != - ]] || { echo 'A certificate-backed signing identity is required.' >&2; exit 1; }
work="$(mktemp -d "${TMPDIR:-/tmp}/terminal-mac-signing.XXXXXX")"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"
cp /usr/bin/true "$work/probe"
codesign --force --sign "$identity" --timestamp=none "$work/probe"
codesign --display --extract-certificates="$work/certificate-" "$work/probe"
fingerprint="$(shasum -a 256 "$work/certificate-0")"; fingerprint="${fingerprint%% *}"
destination=Sources/TerminalMacCore/Signing/SigningFingerprint.txt
if [[ -f "$destination" && "$rotate" = false && "$(< "$destination")" != "$fingerprint" ]]; then
  echo 'The configured certificate differs. Restore its private key, or use --rotate for an explicit trust migration.' >&2
  exit 1
fi
printf '%s\n' "$fingerprint" > "$work/fingerprint"
mv "$work/fingerprint" "$destination"
echo "Configured certificate SHA-256: $fingerprint"
echo 'The local fingerprint is ignored by Git. Rebuild before packaging or running signing tests.'