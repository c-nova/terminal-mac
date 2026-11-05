#!/bin/bash
# Release settings. Nothing personal lives here.
# Public releases are signed with this self-signed identity (create it once with
# scripts/create-signing-identity.sh). It names no person, and because the certificate never changes,
# macOS keeps the guest helper's Screen Recording and Accessibility approvals across updates.
export SIGNING_NAME="${SIGNING_NAME:-TerminalMac Fork Code Signing}"
# Only for `release.sh --notarized`: a notarytool profile from `xcrun notarytool store-credentials PROFILE`.
export NOTARY_PROFILE="${NOTARY_PROFILE:-}"
# GitHub repository (owner/name) that hosts releases.
export GITHUB_REPO="${GITHUB_REPO:-c-nova/terminal-mac}"
