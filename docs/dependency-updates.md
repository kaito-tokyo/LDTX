<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Dependency updates

Dependabot proposes weekly updates for GitHub Actions, the root Swift package,
and AppAuth in the Xcode package lock. No dependency
versions are changed just by enabling this configuration. Review every proposal
and complete the synchronization and validation steps below before merging.

## Swift and XcodeGen

`Package.swift` owns the exact SwiftProtobuf and ArgumentParser pins shared by
SwiftPM and XcodeGen. `project.yml` owns app package declarations. The committed
Xcode `Package.resolved` provides AppAuth update proposals. Dependabot does not
edit XcodeGen YAML. Its root Swift job prioritizes `Package.swift` over Xcode
locks, so a separate `/LDTX.xcodeproj` job discovers `project.xcworkspace` and
updates only `github.com/openid/appauth-ios`. Shared packages are proposed only
through the root job to avoid competing updates.

This uses the supported `swift` ecosystem and the upstream updater's
[Xcode discovery](https://github.com/dependabot/dependabot-core/blob/main/swift/lib/dependabot/swift/file_fetcher.rb),
[lock parsing](https://github.com/dependabot/dependabot-core/blob/main/swift/lib/dependabot/swift/file_parser/package_resolved_parser.rb),
and [Xcode lock updater](https://github.com/dependabot/dependabot-core/blob/main/swift/lib/dependabot/swift/file_updater.rb).
The generated `project.pbxproj` is intentionally untracked. A lock-only AppAuth
proposal therefore needs its new exact version copied to `project.yml` before
Xcode resolves packages; generating and resolving first would restore the old pin.
Confirm the first hosted Dependabot run after this configuration reaches main:
upstream implementation support alone does not prove a hosted run succeeded.

On the proposal branch, run from the repository root:

```sh
python3 Tools/dependencies.py sync
swift package resolve
xcodegen generate
xcodebuild -project LDTX.xcodeproj -scheme LDTXApp \
  -derivedDataPath .derivedData -resolvePackageDependencies
python3 Tools/dependencies.py check
python3 -B -m unittest discover -s Tests/DependencyToolTests
```

`sync` copies shared versions from `Package.swift` and the proposed AppAuth
version from the Xcode lock into `project.yml`. It preserves unrelated YAML.
It does not fabricate lock revisions or origin hashes: SwiftPM and Xcode must
regenerate their own locks. Review both lock diffs and commit them together with
the manifest changes. For a manual AppAuth update, edit its `exactVersion` in
`project.yml`, generate and resolve Xcode, then run `check` (do not run `sync`
against the old AppAuth lock). New app packages require an explicit coverage
policy in the checker and bot configuration.

Check CI rejects mismatched declarations, missing direct lock entries, different
shared commit revisions, and Python source/lock drift (including removed direct
requirements identified by uv annotations). It runs offline with the
Python standard library. It verifies pin consistency, not upstream resolution or
model compatibility. Swift CI runs Linux Corelibs, macOS CLI tests, and the Xcode
`pr` test plan on dependency pull requests. After Xcode package resolution, CI
rejects changes to the tracked Xcode lock, including a regenerated `originHash`;
commit the resolver-produced lock before retrying CI. Run the relevant local
commands from [the build guide](build.md) as well; AppAuth changes require the app-side Xcode
build/tests, not only root SwiftPM tests. SwiftProtobuf changes also require
checking generated Protobuf compatibility and the documented generator version.

## Python model tooling

Model generation is maintained manually under `Tools/MediaPipeLandscapeCoreML/`.
This deliberately supersedes the Python model-tooling Dependabot coverage added
by PR #389; there is no `pip` update scope. Swift, AppAuth and GitHub Actions
coverage remains enabled. This does not change repository security-alert settings.
The unmerged model-tooling proposal PR #390 is superseded by this policy; it is
not closed or modified by this reorganization.

`requirements.txt` contains exact source pins, `requirements.lock` retains the
uv-generated transitive versions and SHA256 hashes, and `.python-version` records
Python 3.13.13 for this tool only. Other Python utilities use the standard library
and do not require this environment. Do not hand-edit transitive versions or hashes.

For a deliberately reviewed model or dependency update, follow the conversion and
lock-regeneration commands in [the build guide](build.md), then run from the
repository root:

```sh
python3 Tools/dependencies.py check
python3 -B -m unittest discover -s Tests/DependencyToolTests
```

Review the full transitive lock diff and regenerated model, then validate model
loading/inference with the app's relevant HardTests and a representative model
compatibility check. A green pin check or ordinary Swift CI does not establish
model compatibility. Source-only dependency changes intentionally fail the pin check
until the lock is regenerated. Transitive-only Python updates remain manual,
using the same coordinated validation. Do not upgrade the entire environment
merely to refresh a single dependency.

## Other update paths and security coverage

GitHub Actions continues to use `gh actions-lock`: after an action proposal,
regenerate and verify `.github/workflows/actions.lock` with a compatible tool
version. This change does not modify action refs or their lock entries.
Vendored doctest (a Git submodule), create-dmg, stb, bundled fonts/model assets,
Hugging Face model revisions, Homebrew tools, Xcode/Swift toolchains, and CI
container/runner versions remain deliberate manual updates. Their licenses,
upstream compatibility and relevant build/test checks must be reviewed.

Read-only API inspection on 2026-10-23 confirmed repository Dependabot alerts
(HTTP 204) and automated security fixes (`enabled: true`, `paused: false`). The
repository metadata also reported Dependabot security updates enabled. The
exported dependency-graph SBOM contained the five direct Python requirements
and GitHub Actions, but no Swift packages or Python lock transitives. This is
an observed coverage limit, not evidence that alerts are disabled. Version
update configuration does not enable security alerts or establish dependency
graph coverage. A maintainer should inspect the repository Dependency graph
and the first bot runs after merge, and decide separately whether Swift or
transitive dependency submission is needed. No settings, permissions, secrets
or submission workflow are changed here.

See GitHub's [supported ecosystems](https://docs.github.com/en/code-security/reference/supply-chain-security/supported-ecosystems-and-repositories)
and [Dependabot options](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-options-reference)
for ecosystem identifiers, schedules and grouping behavior.
