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
pushed. It uses four jobs:

1. `validate-release` verifies the signed annotated tag and reachability from `main`.
2. `wait-for-notarized-app` runs on Linux with the `release-macos` environment, waits for Xcode Cloud
   to finish app notarization, and passes the notarized app and xcarchive Artifact IDs to the next job. It does not download artifacts.
3. `create-release-assets` runs on macOS with the same environment, downloads the stapled notarized app and
   release xcarchive using their Artifact IDs, creates the DMG and dSYM archive, notarizes and staples the DMG,
   records attestations, and uploads the release artifacts.
4. `draft-release` runs on Linux, downloads the release assets, and creates a new draft GitHub Release with
   automatically generated release notes. It fails if a release already exists for the tag.

Xcode Cloud owns app signing and notarization, including the certificate and provisioning-profile boundary. GitHub Actions receives the stapled notarized app as `LDTX.app.zip` and the matching xcarchive for dSYMs. The App Store Connect API key is used to locate those artifacts and for DMG notarization.

## Prerequisites

- The user has merged the Marketing version update PR for the release into `main`.
- The `XC_WORKFLOW_ID` GitHub Actions variable contains the Xcode Cloud release workflow ID.
- That workflow has the Notarize post-action enabled.
- The GitHub Actions environment `release-macos` contains these secrets:
  - `APP_STORE_CONNECT_ISSUER`
  - `APP_STORE_CONNECT_KEY_BASE64`
  - `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_KEY_BASE64` is the App Store Connect private key encoded as base64.
- The environment has required reviewers and deployment-branch or tag restrictions appropriate for release access.
- `release-*` environments must not use custom deployment protection rules. The workflow uses
  `deployment: false` to access environment secrets and variables without creating deployments.
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

The tag must be a cryptographically signed annotated tag. Pushing it starts the matching Xcode Cloud build and the
GitHub release workflow. The Linux wait job waits for the `Notarize - macOS` action to succeed.
Separate steps select the notarized app and release xcarchive Artifact IDs and pass them to the macOS job.

The inline PowerShell wait step uses the `XC_WORKFLOW_ID` GitHub Actions variable and fetches the latest 20 builds in descending build-number order without pagination, selecting the highest-numbered build matching the commit SHA.
It pins that build ID and polls the action list every 30 seconds until notarization succeeds. GitHub Actions limits the wait job to 60 minutes. API errors and terminal Notarize action failures fail immediately.
The artifact selection step retrieves the Notarize action's artifact list once and fails immediately on missing or ambiguous artifacts. The macOS fetch step reads each artifact directly from `/v1/ciArtifacts/{id}` and requires a download URL.
It selects `STAPLED_NOTARIZED_ARCHIVE` from the Notarize action; unnotarized `ARCHIVE_EXPORT` artifacts are never accepted.

JWT generation is provided by `ci_scripts/AppStoreConnectAuth.psm1` using .NET cryptography without external dependencies. Each token includes a scope restricted to the GET request path and query string it authorizes. API requests, polling, and downloads remain in the workflow steps.

### 4. Monitor the release workflow

The tag push starts `Release CD` automatically. Monitor that run:

```sh
gh run list --workflow release.yml --branch v0.1.0 --limit 1
```

The workflow fails when the tag signature is invalid, when the tagged commit is not reachable from `main`, when the
matching Xcode Cloud artifacts do not become available, when DMG notarization fails, or when a release already exists for the tag.

### 5. Verify the draft release

When the workflow succeeds, the draft release should contain:

- `LDTX-<tag>.dmg`.
- `LDTX-<tag>.dSYMs.tar.xz`, containing the `*.dSYM` bundles at the archive root.

The workflow records GitHub artifact attestations separately from Release assets. The workflow packages dSYMs from the matching release xcarchive as a separate release asset. Existing releases, including drafts, are rejected; the workflow does not replace or remove their assets.

### 6. Hand off publishing to a human

A human adds or approves the release notes and publishes the draft. Agents must not publish the release.

## Failure hints

- `Waiting for an Xcode Cloud build ...` or a timeout
  - Confirm `XC_WORKFLOW_ID` identifies the release workflow and that the tag triggered it.
- A missing stapled notarized app
  - Inspect the Archive action and confirm the Notarize post-action succeeded.
- A missing app error
  - Inspect the corresponding Xcode Cloud artifact ZIP layout.
- `Release ... already exists.`
  - Inspect the existing release. A human must remove an unwanted draft before rerunning the draft job.

## Symbolicating a release crash

Use the repository command on macOS with Xcode command-line tools, `gh`, `xz`, and `ditto` available:

```sh
scripts/symbolicate-release-crash ~/Library/Logs/DiagnosticReports/LDTX-2026-08-10.ips
```

The authenticated `gh` account needs read access to Releases in `kaito-tokyo/LDTX`. This includes private and draft
Releases when the account has access; the command passes no credentials itself and does not print authentication
tokens.

The command reads the product, version, build, architecture, application UUID, load address, and application frames
from the `.ips` report. It downloads the exact `v<version>` Release's dSYM archive and matching LDTX DMG
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
