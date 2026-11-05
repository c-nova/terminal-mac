#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -m)" != arm64 ]]; then
  echo 'terminal-mac currently requires Apple silicon.' >&2
  exit 1
fi
configuration="${CONFIGURATION:-release}"
source scripts/release-config.sh
identity="${SIGN_IDENTITY:-}"
# A stable identity keeps the guest helper's Screen Recording and Accessibility approvals across
# updates. Packaged apps must match the pinned certificate; ad-hoc signatures are rejected.
if [[ -z "$identity" ]]; then
  if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGNING_NAME\""; then identity="$SIGNING_NAME"
  else echo "No \"$SIGNING_NAME\" identity. Run scripts/create-signing-identity.sh and scripts/configure-signing.sh for a first build, or restore your existing private key." >&2; exit 1
  fi
fi
[[ "$identity" != - ]] || { echo 'Ad-hoc packages are not accepted by the pinned certificate policy.' >&2; exit 1; }
source scripts/verify-signature.sh
echo "Signing with: $identity"
version="${VERSION:-0.2.0}"
build_number="${BUILD_NUMBER:-6}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo 'VERSION must be x.y.z and BUILD_NUMBER a positive integer.' >&2
  exit 1
fi
# Only Apple-issued certificates get a secure timestamp; it is required for notarization.
case "$identity" in
  -) sign_options=(--timestamp=none) ;;
  'Developer ID Application: '*) sign_options=(--options runtime --timestamp) ;;
  *) sign_options=(--options runtime --timestamp=none) ;;
esac
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
build_options=(--disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/configuration" --security-path "$PWD/.build/security")
swift build "${build_options[@]}" -c "$configuration"
binary_dir="$(swift build "${build_options[@]}" -c "$configuration" --show-bin-path)"
app="$PWD/dist/TerminalMac.app"
guest="$app/Contents/Resources/guest-tools/TerminalMacGuest.app"
mkdir -p "$app/Contents/MacOS" "$guest/Contents/MacOS"
# Replace rather than overwrite: rewriting a running VM's executable in place can kill it.
rm -f "$app/Contents/MacOS/terminal-mac" "$guest/Contents/MacOS/terminal-mac"
cp "$binary_dir/terminal-mac" "$app/Contents/MacOS/terminal-mac"
cp "$binary_dir/terminal-mac" "$guest/Contents/MacOS/terminal-mac"
make_plist() {
  local destination="$1" identifier="$2" name="$3"
  /usr/libexec/PlistBuddy -c 'Clear dict' "$destination" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $identifier" "$destination"
  /usr/libexec/PlistBuddy -c "Add :CFBundleName string $name" "$destination"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string terminal-mac' "$destination"
  /usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$destination"
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" "$destination"
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $build_number" "$destination"
  /usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 14.0' "$destination"
  /usr/libexec/PlistBuddy -c 'Add :NSHighResolutionCapable bool true' "$destination"
}
# The agent skill ships inside the app so `terminal-mac skills get` always matches this build.
rm -rf "$app/Contents/Resources/skills"
mkdir -p "$app/Contents/Resources/skills"
cp -R skills/terminal-mac "$app/Contents/Resources/skills/"
make_plist "$guest/Contents/Info.plist" dev.terminal-mac.guest TerminalMacGuest
make_plist "$app/Contents/Info.plist" dev.terminal-mac.host TerminalMac
rm -rf "$app/Contents/Resources/terminal-mac_TerminalMacCore.bundle" "$guest/Contents/Resources/terminal-mac_TerminalMacCore.bundle"
ditto "$binary_dir/terminal-mac_TerminalMacCore.bundle" "$app/Contents/Resources/terminal-mac_TerminalMacCore.bundle"
ditto "$binary_dir/terminal-mac_TerminalMacCore.bundle" "$guest/Contents/Resources/terminal-mac_TerminalMacCore.bundle"
# Guest has no Virtualization entitlement. Its guarded mode only controls the VM desktop.
codesign --force --sign "$identity" "${sign_options[@]}" "$guest"
codesign --force --sign "$identity" "${sign_options[@]}" --entitlements resources/terminal-mac.entitlements "$app"
ln -sfn TerminalMac.app/Contents/MacOS/terminal-mac dist/terminal-mac
bash scripts/verify-signature.sh "$app"
echo "Built: $PWD/dist/terminal-mac"
