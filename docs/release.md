<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Release Guide

This document describes the release flow for LDTX and the operator checklist that an agent can follow.

## Release architecture

The release pipeline is split across two systems:

1. Xcode Cloud builds the tagged revision and produces a notarized `LDTX.app` artifact from the `On push tag`
   workflow.
2. GitHub Actions runs [`.github/workflows/release.yml`](../.github/workflows/release.yml)
   manually for the same tag, downloads that notarized app, packages it into a DMG, notarizes the DMG, attests
   it, and uploads the assets to a draft GitHub Release.

The GitHub release workflow does not build the app itself. If Xcode Cloud did not finish a successful notarized
tag build first, the workflow will fail.

## Prerequisites

- The Marketing version update PR for the release has been merged into `main`.
- The Xcode Cloud workflow name is exactly `On push tag`.
- The GitHub Actions environment `production-macos` contains these secrets:
  - `APP_STORE_CONNECT_ISSUER`
  - `APP_STORE_CONNECT_KEY_BASE64`
  - `APP_STORE_CONNECT_KEY_ID`
- When an agent runs the Xcode Cloud wait snippet locally, the same values are available as environment
  variables:
  - `APP_STORE_CONNECT_ISSUER`
  - `APP_STORE_CONNECT_KEY_BASE64`
  - `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_KEY_BASE64` stores the App Store Connect private key PEM as a base64-encoded UTF-8 string.
- `gh` is authenticated for the repository when driving the release from CLI.
- The release operator can inspect GitHub Actions and Xcode Cloud run status.

## Version and tag rules

- Update `MARKETING_VERSION` in [`project.yml`](../project.yml) before the release tag is created.
- When `MARKETING_VERSION` changes, include the regenerated `LDTX.xcodeproj` in the same PR.
- The release tag should match `MARKETING_VERSION` with a leading `v`.
- Release tags must start with `v`.
- The workflow accepts only characters allowed by SemVer after the leading `v`.
- Examples:
  - `v0.1.0`
  - `v0.1.0-alpha.1`
  - `v0.1.0-beta.2`
  - `v0.1.0-rc.3`

## Agent operator checklist

### 1. Open the Marketing version update PR and wait for it to be merged

Prepare a dedicated PR for the release version bump before tagging.

- Update `MARKETING_VERSION` in [`project.yml`](../project.yml).
- Regenerate `LDTX.xcodeproj` with `xcodegen generate`.
- Open a PR for the version bump, then wait for a human to merge it to `main`.

While waiting, the agent may use automation support or similar assistive features to watch for the merge and
resume after it lands.

The release tag should be created from the merged version-bump commit or a later commit on `main` that still
carries the same Marketing version.

### 2. Confirm the latest `main` GitHub Actions runs are passing

Use `main` branch CI as the release gate instead of running local validation as part of the release workflow.

```sh
gh run list --branch main --workflow check.yml --limit 1
gh run list --branch main --workflow swift.yml --limit 1
gh run list --branch main --workflow xcode.yml --limit 1
```

Before creating the release tag, confirm that the latest runs for these workflows on `main` completed with
`success`:

- `Check CI`
- `Swift CI`
- `Xcode CI`

If `main` is red, stop and fix CI before continuing with the release.

### 3. Create and push the release tag

Create the tag on the exact commit to release, then push it. The tag should match the current
`MARKETING_VERSION`.

```sh
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

This tag push is what triggers the Xcode Cloud `On push tag` workflow.

### 4. Wait for Xcode Cloud to finish the tag build

Do not dispatch GitHub's release workflow until the tagged Xcode Cloud build:

- matched the same tag, and
- finished successfully, and
- produced a notarized `LDTX.app` artifact.

The custom action
[`./.github/actions/download-xcode-cloud-notarized`](../.github/actions/download-xcode-cloud-notarized) searches
Xcode Cloud for a successful build run that matches the tag or commit SHA. If none exists, `release.yml` fails
before packaging.

An agent may use the same lookup logic directly while waiting:

```javascript
import {
  AppStoreConnectAPI,
  pemFromBase64,
} from './.github/actions/download-xcode-cloud-notarized/app-store-connect-api.mjs';
import {
  findNotarizedBuild,
  normalizeTagRef,
} from './.github/actions/download-xcode-cloud-notarized/notarized-build.mjs';

const api = new AppStoreConnectAPI(
  process.env.APP_STORE_CONNECT_ISSUER,
  process.env.APP_STORE_CONNECT_KEY_ID,
  pemFromBase64(process.env.APP_STORE_CONNECT_KEY_BASE64),
);
const { gitRef, tagName } = normalizeTagRef('v0.1.0');
const result = await findNotarizedBuild({
  api,
  productName: 'LDTX',
  workflowName: 'On push tag',
  tagName,
  gitRef,
  logger: console,
});

console.log(JSON.stringify({
  buildRunId: result.buildRun.id,
  artifactFileName: result.artifact.attributes?.fileName ?? null,
}, null, 2));
```

This command exits successfully only after the notarized artifact is available, so an agent may poll it or wire
it into automation support while waiting.

### 5. Dispatch GitHub's release workflow for the tag

The release workflow is manual (`workflow_dispatch`) and only runs its `release` job when the ref is a tag that
starts with `v`.

With GitHub CLI:

```sh
gh workflow run release.yml --ref v0.1.0
```

Or use the Actions UI and choose the same tag as the ref.

### 6. Verify the draft release output

When the workflow succeeds, it should:

- create or reuse a draft GitHub Release named after the tag,
- upload `LDTX-<tag>.dmg`,
- upload the attestation bundle emitted by `actions/attest`, and
- keep the release in draft state.

The workflow re-uploads assets with `--clobber`, so reruns replace previously uploaded files for the same tag.

### 7. Finalize release notes and publish

`release.yml` creates the draft release with empty notes:

```sh
gh release create "$GITHUB_REF_NAME" --draft --notes "" --title "$GITHUB_REF_NAME"
```

After the draft appears, add human-written release notes and publish the release.

## Failure hints

- `No successful Xcode Cloud build run matched tag ...`
  - The tag was not pushed, Xcode Cloud has not finished yet, or the wrong tag was selected when dispatching the
    workflow.
- `No successful Notarize action was found ...`
  - Xcode Cloud built the app, but the notarization step in Xcode Cloud did not complete successfully.
- `LDTX.app was not found in notarized artifact ...`
  - The downloaded Xcode Cloud artifact format changed or the wrong artifact was selected.
- GitHub Release exists but has stale assets
  - Re-run `release.yml`; asset upload uses `--clobber`.

## Suggested agent handoff format

When the agent finishes the operator part of a release, report:

- the Marketing version update PR URL or commit,
- the tag name,
- which `main` GitHub Actions workflows were confirmed green,
- whether Xcode Cloud finished successfully,
- whether `release.yml` finished successfully,
- the draft release URL, and
- whether release notes still need manual editing.
