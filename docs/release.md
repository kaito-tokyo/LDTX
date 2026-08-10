<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Release Guide

This document describes the Developer ID release flow for LDTX and the operator checklist that an agent can follow.

## Human-only operations

The following operations must always be performed by a human and are prohibited for agents:

- merging a pull request, and
- publishing a GitHub Release.

Agents may prepare and create commits, push commits and tags, create or update draft pull requests, run the release
workflow, and create or update draft GitHub Releases. An agent must stop after verifying the draft release and hand
the final merge or Publish action to a human.

## Release architecture

[`.github/workflows/release.yml`](../.github/workflows/release.yml) starts automatically when a `v`-prefixed tag is
pushed. It uses two jobs:

1. `validate-release` verifies the signed annotated tag and reachability from `main`.
2. After the `release-macos` environment review, `sign-release` waits for the matching Xcode Cloud Archive artifacts,
   downloads the Developer ID app exports and xcarchives, verifies their versions, notarizes and staples the apps and
   DMGs, records attestations for the release assets, and creates or updates the draft GitHub Release.

Xcode Cloud owns the certificate and provisioning-profile boundary. GitHub Actions receives only the signed app
exports and matching xcarchives. The App Store Connect API key is used to locate those artifacts and for notarization.

## Prerequisites

- The user has merged the Marketing version update PR for the release into `main`.
- The Xcode Cloud workflow names are exactly `On push tag - LDTX` and `On push tag - LDTXTiny`.
- The GitHub Actions environment `release-macos` contains these secrets:
  - `APP_STORE_CONNECT_ISSUER`
  - `APP_STORE_CONNECT_KEY_BASE64`
  - `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_KEY_BASE64` is the App Store Connect private key encoded as base64.
- The environment has required reviewers and deployment-branch or tag restrictions appropriate for release access.
- `gh` is authenticated for the repository when driving the release from CLI.

## Version and tag rules

- Prepare release work on a dedicated branch named `releases/<tag>`.
- Update `MARKETING_VERSION` in [`project.yml`](../project.yml) before the release tag is created.
- `LDTX.xcodeproj` is generated and ignored; `project.yml` is the release version source of truth.
- The release tag must match the archived apps' Marketing version with a leading `v`.

Examples include `v0.1.0`, `v0.1.0-beta.2`, and `v0.1.0-rc.3`.

## Agent operator checklist

### 1. Open the Marketing version update PR

Start from the latest `origin/main`, create a branch such as `releases/v0.1.0`, and update `MARKETING_VERSION` in
[`project.yml`](../project.yml). A human must review and merge the PR.

### 2. Confirm main CI is passing

Confirm the latest `Check CI`, `Swift CI`, and `Xcode CI` runs for `main` completed successfully. If `main` is red,
stop and fix CI before continuing.

### 3. Create and push the release tag

Create the tag on the exact commit to release, then push it:

```sh
git tag -s v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

The tag must be a cryptographically signed annotated tag. Pushing it starts the matching Xcode Cloud builds and the
GitHub release workflow. The release job waits for both Xcode Cloud Archive artifact sets.

### 4. Monitor the release workflow

The tag push starts `Release CD` automatically. Monitor that run:

```sh
gh run list --workflow release.yml --branch v0.1.0 --limit 1
```

The workflow fails when the tag signature is invalid, when the tagged commit is not reachable from `main`, when the
matching Xcode Cloud artifacts do not become available, or when an archived app version does not match the tag.

### 5. Verify the draft release

When the workflow succeeds, the draft release should contain:

- `LDTX-<tag>.dmg`,
- `LDTXTiny-<tag>.dmg`,
- `LDTX-<tag>.dSYMs.cpio.xz`, with separate `dSYMs/LDTX` and `dSYMs/LDTXTiny` directories.

The workflow records GitHub artifact attestations separately from Release assets and packages the dSYMs collected by
Xcode. When reusing an existing draft, it replaces the current asset set first, then removes any obsolete assets.

### 6. Hand off publishing to a human

A human adds or approves the release notes and publishes the draft. Agents must not publish the release.

## Failure hints

- `No Xcode Cloud build run matched tag ...`
  - Confirm the tag triggered both Xcode Cloud workflows and that their configured names have not changed.
- A missing Developer ID export or xcarchive
  - Inspect the corresponding Xcode Cloud Archive action and its distribution configuration.
- `Release tag ... does not match app version ...`
  - Create the tag from the commit whose archived app version matches the intended release.
- A missing app or dSYM error
  - Inspect the corresponding Xcode Cloud artifact and archive layout.
- A stale draft release asset
  - Rerun `release.yml`; asset upload uses `--clobber`.

## Symbolicating a release crash

Use the repository command on macOS with Xcode command-line tools, `gh`, `xz`, and `ditto` available:

```sh
scripts/symbolicate-release-crash ~/Library/Logs/DiagnosticReports/LDTX-2026-08-10.ips
```

The authenticated `gh` account needs read access to Releases in `kaito-tokyo/LDTX`. This includes private and draft
Releases when the account has access; the command passes no credentials itself and does not print authentication
tokens.

The command reads the product, version, build, architecture, application UUID, load address, and application frames
from the `.ips` report. It downloads the exact `v<version>` Release's dSYM archive and matching LDTX or LDTXTiny DMG
into a new temporary directory. It verifies the downloaded bundle identifier, version, and build, then requires the
crash, executable, and product-specific dSYM UUIDs to match for the reported architecture before invoking `atos`.
Missing assets, ambiguous Binary Images entries, incomplete reports, metadata differences, and UUID differences are
fatal; the command never guesses another Release or symbol file.

Output is limited to the release tag, application metadata, matched UUID, application frames, unresolved-frame count,
and the corresponding source tag URL. Apple system frames and dependency frames are not sent to `atos` and remain
outside the application-frame report. dSYM contents are neither printed nor uploaded. Temporary downloads are removed
unless `--keep-temporary-files` is supplied for local debugging.

## Suggested agent handoff format

Report the Marketing version PR or commit, tag name, confirmed CI runs, `release.yml` result, draft release URL,
remaining release-note work, and an explicit reminder that a human must publish the release.
