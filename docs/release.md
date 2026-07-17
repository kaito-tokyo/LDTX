<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Release Guide

This document describes the release flow for LDTX and the operator checklist that an agent can follow.

## Human-only operations

The following operations must always be performed by a human and are prohibited for agents:

- merging a pull request, and
- publishing a GitHub Release.

Agents may prepare and create commits, push commits and tags, create or update draft pull requests, run the release
workflow, and create or update draft GitHub Releases. An agent must stop after verifying the draft release and hand
the final merge or Publish action to a human.

## Release architecture

The release pipeline is split across two systems:

1. Xcode Cloud builds the tagged revision and produces a notarized `LDTX.app` artifact from the `On push tag`
   workflow, plus the matching `xcarchive` that contains release `dSYM`s.
2. GitHub Actions runs [`.github/workflows/release.yml`](../.github/workflows/release.yml)
   manually for the same tag, downloads the notarized app and matching `xcarchive`, packages the app into a DMG,
   compresses the archive's `dSYM`s into `LDTX-<tag>.dSYMs.cpio.xz`, notarizes the DMG, attests it, and uploads
   the assets to a draft GitHub Release.

The GitHub release workflow does not build the app itself. If Xcode Cloud did not finish a successful notarized
tag build first, the workflow will fail.

## Prerequisites

- The user has merged the Marketing version update PR for the release into `main`.
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

- Prepare release work on a dedicated branch named `releases/<tag>`.
- The branch suffix should reuse the exact release tag, including the leading `v`.
- Examples:
  - `releases/v0.1.0`
  - `releases/v0.1.0-rc.1`
- Update `MARKETING_VERSION` in [`project.yml`](../project.yml) before the release tag is created.
- `LDTX.xcodeproj` is generated and ignored in this repository; treat `project.yml` as the release version source of
  truth.
- The release tag should match `MARKETING_VERSION` with a leading `v`.
- Release tags must start with `v`.
- The workflow accepts only characters allowed by SemVer after the leading `v`.
- Examples:
  - `v0.1.0`
  - `v0.1.0-alpha.1`
  - `v0.1.0-beta.2`
  - `v0.1.0-rc.3`

## Agent operator checklist

### 1. Open the Marketing version update PR and wait for a human to merge it

Prepare a dedicated PR for the release version bump before tagging.

Start from the latest `origin/main` and create the release branch using the release tag format:

```sh
git fetch origin main
git switch -c releases/v0.1.0 origin/main
```

- Update `MARKETING_VERSION` in [`project.yml`](../project.yml).
- Regenerate `LDTX.xcodeproj` locally with `xcodegen generate` when you need to build or inspect the app before the
  PR is merged.
- Open a PR from `releases/v0.1.0` (or the matching release branch for that version).
- A human reviews and merges that PR into `main`. Agents must not perform the merge.

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
- produced a notarized `LDTX.app` artifact, and
- produced the matching `xcarchive` artifact with the release `dSYM`s.

The custom action
[`./.github/actions/download-xcode-cloud-notarized`](../.github/actions/download-xcode-cloud-notarized) searches
Xcode Cloud for a successful build run that matches the tag or commit SHA. `release.yml` now fails before
packaging unless both the notarized app artifact and the matching `xcarchive` artifact are downloadable.

The release helpers are intentionally split into small pieces so agents can compose their own background jobs
instead of editing one large script:

- [`./ci_scripts/xcode_cloud_release.mjs`](../ci_scripts/xcode_cloud_release.mjs): reusable Xcode Cloud polling
  helpers.
- [`./ci_scripts/github_release_workflow.mjs`](../ci_scripts/github_release_workflow.mjs): reusable `gh` workflow
  dispatch and watch helpers.
- [`./ci_scripts/wait_for_xcode_cloud_notarized.mjs`](../ci_scripts/wait_for_xcode_cloud_notarized.mjs): thin CLI
  that waits only for the Xcode Cloud artifact.
- [`./ci_scripts/run_release_after_tag.mjs`](../ci_scripts/run_release_after_tag.mjs): thin orchestration CLI built
  from those helpers.
- [`./ci_scripts/run_release_after_tag.sh`](../ci_scripts/run_release_after_tag.sh): convenience wrapper that only
  adds background execution and log/status file management.

If you want an agent to wait in the background without committing to a full release flow yet, start only the
Xcode Cloud wait step:

```sh
nohup node ./ci_scripts/wait_for_xcode_cloud_notarized.mjs v0.1.0 \
  > .derivedData/release-watch/v0.1.0-xcode-cloud.log 2>&1 </dev/null &
```

If you want the full wait-dispatch-watch path, launch the convenience wrapper in the background right after pushing
the tag:

```sh
./ci_scripts/run_release_after_tag.sh --background v0.1.0
```

This convenience wrapper:

- polls Xcode Cloud until the notarized app artifact and matching `xcarchive` are available,
- dispatches `release.yml` for the same tag, and
- waits for the GitHub Actions run to finish.

It writes a log and status file under `.derivedData/release-watch/`, so the operator can inspect progress without
keeping a terminal blocked.

If you want only the Xcode Cloud wait logic in the foreground, use:

```sh
node ./ci_scripts/wait_for_xcode_cloud_notarized.mjs v0.1.0
```

The helper resolves the commit SHA from the local tag instead of relying on `GITHUB_SHA`. Fetch the tag first if
it is not already available in the local repository.

### 5. Dispatch GitHub's release workflow for the tag

The release workflow is manual (`workflow_dispatch`) and must be dispatched against the same `v`-prefixed tag that
Xcode Cloud built.

The workflow now fails immediately when:

- it is dispatched from a branch or a non-tag ref, or
- the selected tag does not match `MARKETING_VERSION` in [`project.yml`](../project.yml).

With GitHub CLI:

```sh
gh workflow run release.yml --ref v0.1.0
```

When the operator already resolved the matching Xcode Cloud build run locally, pass it to the workflow so GitHub
Actions does not need to rediscover the same build:

```sh
gh workflow run release.yml --ref v0.1.0 -f build_run_id=<xcode-cloud-build-run-id>
```

Or use the Actions UI and choose the same tag as the ref.

When you started [`./ci_scripts/run_release_after_tag.sh`](../ci_scripts/run_release_after_tag.sh), this dispatch
step is handled automatically after the Xcode Cloud artifact appears, and the helper forwards the resolved
`build_run_id`.

### 6. Verify the draft release output

When the workflow succeeds, it should:

- create or reuse a draft GitHub Release named after the tag,
- upload `LDTX-<tag>.dmg`,
- upload `LDTX-<tag>.dSYMs.cpio.xz`,
- upload the attestation bundle emitted by `actions/attest`, and
- keep the release in draft state.

The workflow re-uploads assets with `--clobber`, so reruns replace previously uploaded files for the same tag.

### 7. Hand off release notes and publishing to a human

`release.yml` creates the draft release with empty notes:

```sh
gh release create "$GITHUB_REF_NAME" --draft --notes "" --title "$GITHUB_REF_NAME"
```

After the draft appears, a human adds or approves the release notes and publishes the release. Agents must not use
the GitHub UI, GitHub CLI, API, or any other mechanism to publish it. The agent's release work ends with a verified
draft and a handoff to the human operator.

## Failure hints

- `No successful Xcode Cloud build run matched tag ...`
  - The tag was not pushed, Xcode Cloud has not finished yet, or the wrong tag was selected when dispatching the
    workflow.
- `Could not find the dispatched release.yml run for ...`
  - The helper dispatched the workflow, but GitHub did not surface the run in time; inspect Actions manually and
    re-run the watcher if needed.
- `Release workflow must be dispatched against a v-prefixed tag ref ...`
  - The workflow was started from a branch or another non-tag ref instead of the release tag.
- `Release tag ... does not match MARKETING_VERSION ...`
  - The tag and [`project.yml`](../project.yml) disagree; update the Marketing version PR or recreate the tag from
    the correct revision.
- `No successful Notarize action was found ...`
  - Xcode Cloud built the app, but the notarization step in Xcode Cloud did not complete successfully.
- `No downloadable xcarchive artifact was found ...`
  - Xcode Cloud finished the build, but the archive artifact was missing, renamed, or not downloadable yet.
- `LDTX.app was not found in notarized artifact ...`
  - The downloaded Xcode Cloud artifact format changed or the wrong artifact was selected.
- `No .xcarchive directory was found in artifact ...`
  - The downloaded archive artifact format changed or the wrong archive artifact was selected.
- `No dSYMs directory was found in xcarchive ...`
  - Xcode Cloud produced an archive without symbol files, so the workflow could not package release `dSYM`s.
- GitHub Release exists but has stale assets
  - Re-run `release.yml`; asset upload uses `--clobber`.

## Suggested agent handoff format

When the agent finishes the operator part of a release, report:

- the Marketing version update PR URL or commit, including whether the user has already merged it,
- the tag name,
- which `main` GitHub Actions workflows were confirmed green,
- whether Xcode Cloud finished successfully,
- whether `release.yml` finished successfully,
- the draft release URL, and
- whether release notes still need manual editing, and
- an explicit reminder that a human must publish the release.
