<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Dependency updates

Dependabot proposes weekly updates for GitHub Actions, Git submodules,
and the app's AppAuth and ArgumentParser dependencies. Review each proposal and
validate the affected build graphs before merging.

## Swift and XcodeGen

`Vendors/nanopb` pins the nanopb runtime and generator as a Git submodule.
`Packages/LDTXCorelibs/Package.swift` references its official local SwiftPM package
and owns the adapter targets' C/Swift configuration macros.
`project/corelibs.yml` references the Corelibs local package. `project.yml` owns AppAuth and
ArgumentParser declarations. There is no root Package.swift. Dependabot's
Git submodule scope updates nanopb; the separate
`/LDTX.xcodeproj` scope proposes AppAuth and ArgumentParser lock updates.

For an Xcode lock proposal, copy the proposed version to the corresponding
`exactVersion` in project.yml before regenerating or resolving the project.
Otherwise Xcode's resolver will restore the old manifest pin. For a nanopb
update, use the same pinned checkout for the runtime and official C generator.
The Python generator's protobuf runtime and Jinja2 are pinned in the PEP 723 inline metadata
of `.agents/skills/generate-nanopb-protos/scripts/generate-nanopb-headers.py`. pipx with the pip backend manages
its isolated environment;
keep the pin compatible with the external protoc version used to prepare descriptors.

```sh
swift package --package-path Packages/LDTXCorelibs resolve
xcodegen generate
xcodebuild -project LDTX.xcodeproj -scheme LDTXApp \
  -derivedDataPath .derivedData -resolvePackageDependencies
```

Review the manifests and resolver-produced locks together. nanopb's revision is
recorded by the Git submodule rather than a SwiftPM lock. The generated
project.pbxproj is intentionally untracked. New app packages require a deliberate
Dependabot coverage policy. Confirm hosted Dependabot behavior after this
configuration reaches main.

CI runs Linux Corelibs and the Xcode pr plan, including CLI and macOS
protobuf-extra tests. After Xcode resolution, CI rejects changes to the tracked
Xcode lock, including originHash; commit the resolver-produced lock before
retrying CI. nanopb changes also require checking configuration macros, codec
round trips, official C header regeneration, and `generate-nanopb-headers.py --check` against an external descriptor as described
in the [generator guide](../.agents/skills/generate-nanopb-protos/references/generation.md).

## Python model tooling

Model generation is maintained manually under `Tools/MediaPipeLandscapeCoreML/`.
This deliberately supersedes the Python model-tooling Dependabot coverage added
by PR #389; there is no `pip` update scope. Swift, AppAuth and GitHub Actions
coverage remains enabled. This does not change repository security-alert settings.
The unmerged model-tooling proposal PR #390 is superseded by this policy; it is
not closed or modified by this reorganization.

`requirements.txt` contains exact source pins, and `.python-version` records
Python 3.13.13 for this tool only. Other Python utilities use the standard library
and do not require this environment. There is no model-tooling dependency lock;
transitive dependencies are resolved during installation and are not hash-verified
or pinned as a complete environment. The application build consumes the committed
model resource and does not install these conversion dependencies.

For a deliberately reviewed model or dependency update, follow the conversion
commands in [the build guide](build.md). Review changed source pins and the
regenerated model, then validate model loading/inference with the app's relevant
HardTests and a representative model compatibility check. Ordinary Swift CI does
not establish model compatibility. Do not upgrade the entire environment merely
to refresh a single dependency.

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
