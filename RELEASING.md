# Releasing terminal-mac

The customer package contains precompiled signed apps and a user-local installer. Customers do not need Swift, Xcode, or a separately downloaded helper. macOS itself is fetched from Apple on first run, rather than bundled into the CLI archive.

## Signing

Source builders and fork maintainers create their own signing identity. No certificate, private key or individual fingerprint is committed. Users installing a prebuilt release use its publisher's signature and do not need to create a certificate. A public certificate alone cannot sign an app; signing requires its private key.

For a first build, use a self-signed code-signing identity in your login keychain. It requires no Apple account. The default name is **"TerminalMac Fork Code Signing"**; the same name on another Mac does not imply the same certificate.

```sh
bash scripts/create-signing-identity.sh
bash scripts/configure-signing.sh
bash scripts/build.sh
```

To use a different name, keep it set for setup, builds and releases:

```sh
export SIGNING_NAME='My TerminalMac Code Signing'
bash scripts/create-signing-identity.sh
bash scripts/configure-signing.sh
bash scripts/build.sh
```

`configure-signing.sh` signs a temporary probe with the selected identity and extracts that actual signer's certificate. It writes only its SHA-256 to `Sources/TerminalMacCore/Signing/SigningFingerprint.txt`, which is ignored by Git. Temporary certificates are deleted; the private key stays in the keychain. `SIGN_IDENTITY` can select an existing identity by name or fingerprint.

Builds embed the generated fingerprint in both signed apps. Releases render it as a fixed value in `verify-signature.sh`; they do not ship a separate `.cer` file. Certificates are necessarily included in the apps' normal code signatures, but are not repository configuration. Do not read a candidate app's own fingerprint as the trust authority: guest updates compare its signer against the running helper's trusted fingerprint.

Installation verifies host and embedded guest signature integrity, identifiers and leaf certificate SHA-256 before copying, after staging and before reusing an existing versioned installation. Guest installation and shared-tools updates verify the candidate against the running helper's trusted resources before replacement or launch. Same-named foreign certificates, missing configuration and ad-hoc signatures are rejected. `swift build` and ordinary unit tests work before signing is configured; packaging requires configuration, and unconfigured guest installation/updates fail closed.

**Back it up:** Keychain Access → My Certificates → your identity → Export the certificate and private key as a password-protected PKCS#12 file. Keep the backup outside the repository. On another build Mac, restore that key, then run `configure-signing.sh` to regenerate the same fingerprint. Losing the private key cannot be repaired by generating a same-named certificate.

To deliberately rotate to a different existing identity, run `SIGN_IDENTITY='New Identity' bash scripts/configure-signing.sh --rotate`, then rebuild and package using that identity. Without `--rotate`, a different fingerprint is refused. The certificate-creation script also refuses to issue a new identity when a local fingerprint is already configured: restore the key, or remove the ignored fingerprint only as part of a deliberate rotation. A new signing key requires explicit guest reinstallation and renewed privacy approvals. Upstream-signed and ad-hoc guest installations likewise cannot silently migrate to your certificate. Remove the old guest helper inside the VM, install your new helper and grant its privacy permissions again; do not remove VM data.

The installer script and its fixed fingerprint still need a trusted delivery path. Replacing the installer or `get.sh` itself is outside this app-signature check; self-signing is not Apple notarization or proof of safe VM isolation.

Files downloaded with `curl` are not quarantined, so Gatekeeper does not require notarization for them. A ZIP downloaded in a browser is quarantined and Gatekeeper will block it, so the README points users to the curl installer.

## Commands

```sh
# Public release, self-signed (default):
VERSION=0.2.0 BUILD_NUMBER=6 bash scripts/release.sh

# Local debug package with the same pinned certificate (no upload):
CONFIGURATION=debug VERSION=0.2.0 BUILD_NUMBER=7 bash scripts/release.sh
```

Increment the positive integer `BUILD_NUMBER` for each build: installed guest helpers update themselves when a higher build appears. `VERSION` uses `major.minor.patch`. Archives are immutable; the scripts refuse to replace an existing release with the same version and build.

Settings in `scripts/release-config.sh`:

- Signing identity: `SIGNING_NAME` (default "TerminalMac Fork Code Signing"); `SIGN_IDENTITY` may select the same pinned certificate by name or fingerprint. Different certificates and `SIGN_IDENTITY=-` are rejected.
- Notary profile (only `--notarized`): `NOTARY_PROFILE`, created with `xcrun notarytool store-credentials PROFILE`. Credentials stay in the Keychain.
- Host bundle: `dev.terminal-mac.host`; guest bundle: `dev.terminal-mac.guest`.
- Architecture: arm64; minimum macOS: 14.
- Artifacts: `dist/releases/terminal-mac-VERSION-BUILD-macos-arm64.zip` and `.zip.sha256` (`--local` adds a `-local` suffix).

Each self-signed app is signed independently with Hardened Runtime and no secure timestamp. The guest has no Virtualization entitlement; the host has `com.apple.security.virtualization`. The legacy `--local` mode is rejected by the pin policy. `--notarized` requires configuring the fingerprint of a Developer ID certificate with its private key available and setting `NOTARY_PROFILE`; it cannot use a self-signed identity.

## Test the package

Extract the release ZIP into a clean temporary location, then:

```sh
bash install.sh --prefix /tmp/terminal-mac-install-test
/tmp/terminal-mac-install-test/bin/terminal-mac --version
/tmp/terminal-mac-install-test/bin/terminal-mac doctor
/tmp/terminal-mac-install-test/bin/terminal-mac up --plan
```

The installed launcher points to a complete versioned app bundle under `PREFIX/lib/terminal-mac`. Do not distribute only the inner executable: that loses the signed resources and bundled guest tools. The installer switches the launcher to the new version and leaves VM data under the user's Library untouched. It does not overwrite unrelated executables or edit shell profiles.

Before announcing production readiness, finish the live guest checklist in `docs/VALIDATION.md`, ideally on a separate clean Mac. Notarization verifies distribution signing; it does not prove VM boot, guest setup, privacy grants, input or terminal rendering work correctly.

Run regression checks with the private key available locally:

```sh
TERMINAL_MAC_TEST_SIGNING_IDENTITY='TerminalMac Fork Code Signing' swift test
TERMINAL_MAC_TEST_SIGNING_IDENTITY='TerminalMac Fork Code Signing' bash scripts/test-package.sh /absolute/path/to/release.zip
```

Without that environment variable the Swift positive-signing test and nested foreign-signer package test are skipped. Package checks use temporary prefixes and an ephemeral test keychain, verify rejection of unsigned, ad-hoc, tampered and same-named foreign signatures, and confirm the existing launcher and executable remain unchanged. No VM is started.

## Publishing (GitHub Releases and curl)

The repository is `GITHUB_REPO` in `scripts/release-config.sh` (default `c-nova/terminal-mac`). With it set, `release.sh` also writes `dist/releases/NAME-publish/`, which contains:

- the archive and its `.sha256`;
- `get.sh`, the curl installer, pinned to this archive's URL and checksum.

To publish, create a GitHub release tagged `vVERSION-BUILD` (for example `v0.2.0-6`) and attach every file in that folder: on github.com under Releases → Draft a new release, or with `gh release create v0.2.0-6 dist/releases/terminal-mac-0.2.0-6-macos-arm64-publish/* --title "terminal-mac 0.2.0"`.

After a release has been published, users can install with `curl -fsSL https://github.com/c-nova/terminal-mac/releases/latest/download/get.sh | bash`. Because `get.sh` is attached to each release, `latest/download/get.sh` installs the newest published release. Public releases are self-signed (see Signing).

The repository is also a Claude Code plugin marketplace. `.claude-plugin/plugin.json` registers the MCP server (`terminal-mac mcp`, which must be on PATH) and the skill in `skills/`. Users run `/plugin install terminal-mac --marketplace govijr/terminal-mac`. Check with `claude plugin validate .`, and keep `plugin.json`'s version in step with `VERSION`. The same `skills/` folder works with `npx skills add govijr/terminal-mac --skill terminal-mac`.

## Hosting and current release status

Fork releases are configured for `c-nova/terminal-mac`. Release scripts produce local immutable artifacts and upload-ready files; they never publish. The signing checks have been exercised with local debug packages only; no fork release has been uploaded.

Public releases are self-signed and are not uploaded to Apple. `--notarized` is optional and has not been run.
