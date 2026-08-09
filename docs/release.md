<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Release Guide

This document describes the direct Developer ID release flow for LDTX and the operator checklist that an agent can
follow. Xcode Cloud is not part of this flow.

## Human-only operations

The following operations must always be performed by a human and are prohibited for agents:

- merging a pull request, and
- publishing a GitHub Release.

Agents may prepare and create commits, push commits and tags, create or update draft pull requests, run the release
workflow, and create or update draft GitHub Releases. An agent must stop after verifying the draft release and hand
the final merge or Publish action to a human.

## Release architecture

[`.github/workflows/release.yml`](../.github/workflows/release.yml) runs manually for a release tag on a GitHub-hosted
macOS runner. It:

1. checks that the selected tag and `MARKETING_VERSION` agree,
2. imports the Developer ID certificate into an ephemeral keychain,
3. generates the Xcode project and archives the `LDTX` and `LDTXTiny` schemes with automatic provisioning,
4. verifies the Developer ID signatures and matching dSYMs,
5. notarizes and staples both apps,
6. packages, notarizes, staples, and verifies both DMGs,
7. attests the DMGs and uploads them with the dSYM archive to a draft GitHub Release.

The certificate import uses the same pinned `kaito-tokyo/setup-apple-codesigning` action as
`unite-analysis-swift`. The App Store Connect API key is written only to a temporary file and is used by
`xcodebuild` for provisioning and by `notarytool` for notarization.

## Prerequisites

- The user has merged the Marketing version update PR for the release into `main`.
- The GitHub Actions environment `release-macos` contains these secrets:
  - `APP_STORE_CONNECT_ISSUER`
  - `APP_STORE_CONNECT_KEY_BASE64`
  - `APP_STORE_CONNECT_KEY_ID`
  - `MACOS_SIGNING_CERT`
  - `MACOS_SIGNING_CERT_PASSWORD`
- The environment contains the variable `MACOS_SIGNING_APPLICATION_IDENTITY`.
- `MACOS_SIGNING_CERT` is a base64-encoded PKCS#12 containing the matching Developer ID Application identity.
- `APP_STORE_CONNECT_KEY_BASE64` is the App Store Connect private key encoded as base64.
- The environment has required reviewers and deployment-branch or tag restrictions appropriate for release signing.
- `gh` is authenticated for the repository when driving the release from CLI.

## Version and tag rules

- Prepare release work on a dedicated branch named `releases/<tag>`.
- Update `MARKETING_VERSION` in [`project.yml`](../project.yml) before the release tag is created.
- `LDTX.xcodeproj` is generated and ignored; `project.yml` is the release version source of truth.
- The release tag must match `MARKETING_VERSION` with a leading `v` and contain only SemVer characters.

Examples include `v0.1.0`, `v0.1.0-beta.2`, and `v0.1.0-rc.3`.

## Agent operator checklist

### 1. Open the Marketing version update PR

Start from the latest `origin/main`, create a branch such as `releases/v0.1.0`, and update `MARKETING_VERSION` in
[`project.yml`](../project.yml). A human must review and merge the PR.

### 2. Confirm main CI is passing

Confirm the latest `Check CI`, `Swift CI`, and `Xcode CI` runs on `main` completed successfully. If `main` is red,
stop and fix CI before continuing.

### 3. Create and push the release tag

Create the tag on the exact commit to release, then push it:

```sh
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

### 4. Dispatch the release workflow

Dispatch the workflow against the same tag:

```sh
gh workflow run release.yml --ref v0.1.0
```

The workflow fails immediately when selected from a branch or when the tag does not match `MARKETING_VERSION`.

### 5. Verify the draft release

When the workflow succeeds, the draft release should contain:

- `LDTX-<tag>.dmg`,
- `LDTXTiny-<tag>.dmg`,
- `LDTX-<tag>.dSYMs.cpio.xz`, with separate `dSYMs/LDTX` and `dSYMs/LDTXTiny` directories, and
- the attestation bundle emitted by `actions/attest`.

The workflow verifies signatures and dSYM UUIDs before packaging. It then mounts each notarized DMG and verifies the
expected app, `/Applications` link, code signature, stapled ticket, and Gatekeeper assessment. Reruns replace assets
for the same tag with `--clobber`.

### 6. Hand off publishing to a human

A human adds or approves the release notes and publishes the draft. Agents must not publish the release.

## Failure hints

- `Signing identity ... was not found.`
  - Confirm the PKCS#12 secret contains the identity named by `MACOS_SIGNING_APPLICATION_IDENTITY`.
- A provisioning-profile error from `xcodebuild`
  - Confirm the App Store Connect API key can manage signing assets and that the application identifiers and iCloud
    containers exist for the production bundle IDs.
- `Release tag ... does not match MARKETING_VERSION ...`
  - Update the Marketing version PR or dispatch the workflow for the correct tag.
- A missing app or dSYM error
  - Inspect the corresponding `xcodebuild archive` log and generated archive layout.
- A stale draft release asset
  - Rerun `release.yml`; asset upload uses `--clobber`.

## Suggested agent handoff format

Report the Marketing version PR or commit, tag name, confirmed CI runs, `release.yml` result, draft release URL,
remaining release-note work, and an explicit reminder that a human must publish the release.
