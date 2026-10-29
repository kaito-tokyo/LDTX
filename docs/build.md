<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Build Guide

See [dependency updates](dependency-updates.md) for Dependabot coverage, manifest
and lock synchronization, and validation of update proposals.

XcodeGen targets use C11 and C++20. Swift uses Objective-C interoperability;
native AudioMixEngine unit tests run in the existing CMake test executable.
Debug skips framework module verification. Release and Distribution retain it;
use `ENABLE_MODULE_VERIFIER=YES` to enable it explicitly for a Debug build.

Debug enables compiler caching and path normalization, including generated
module maps. CI applies these settings to package targets and preserves
`.derivedData/CompilationCache.noindex` between runs. A clean build can reuse
this cache; the first build still compiles uncached inputs. Release and
Distribution keep their existing cache settings.
Use `COMPILATION_CACHE_ENABLE_CACHING=NO` to build without compiler-result reuse.

The CI build-for-testing step uses `ci_scripts/production-swift-batching.xcconfig`
to limit Debug production Swift targets and package library dependencies to four
compiler batches. Test bundles retain their existing compiler flags and batch
selection. Local builds, Release, and Distribution keep their defaults. CI logs
include Xcode's build timing summary; its parallel task totals are not wall-clock
build times.

**Set up Protobuf tools when needed:**

```sh
brew install protobuf
```

## Corelibs

`Packages/LDTXCorelibs/Package.swift` defines the Swift targets `LDTXCorelibs`
and `LDTXMessages`, and the C target `LDTXNanopbGenerated`. Sources live under
`Packages/LDTXCorelibs/Sources/<target>`. There is no repository-root manifest.
`LDTXMessages` owns Protobuf models, handwritten message extensions, and the
copying codec. `LDTXCorelibs` owns `Values`, `Program`, `WorkspaceBundleFormat`,
and `RecordBundleFormat`, and re-exports the public Swift message API.
See [target dependencies](target-dependencies.md) for their boundaries and
Workspace UI's presentation contracts.

XcodeGen references the local package's dynamic `LDTXCorelibs` product, and all
Swift consumers use `import LDTXCorelibs`. One dynamic product provides a single
implementation across the application's framework graph. The vendored nanopb
target and generated C target are internal imports of `LDTXMessages`. The
vendored `pb.h` defines the shared nanopb configuration macros. AVFoundation
operations remain in LDTXRecording outside Corelibs.

On Linux, files that only use Foundation's Swift value APIs import
FoundationEssentials. Files using compatibility APIs such as JSONSerialization,
NSNumber, NSDecimalNumber, NSString, NSURLErrorKey, PropertyListSerialization,
and XMLParser retain Foundation. Generated message models and the shared nanopb
codec follow the same rule; their generator emits the conditional import.
Apple platforms use the SDK's Foundation module. Pure Swift values need neither.

Tests live in `Packages/LDTXCorelibs/Tests/LDTXCorelibsTests/<area>` and are defined once as
SwiftPM's `LDTXCorelibsTests`. `project/corelibs.yml` references that package
target directly; XcodeGen does not create another test
bundle or source group.

```sh
swift build --package-path Packages/LDTXCorelibs
swift test --package-path Packages/LDTXCorelibs
```

GitHub Codespaces uses `.devcontainer/devcontainer.json` to resolve this package.
pipx and Python are needed only when regenerating message sources. The pinned
`grpcio-tools` package provides protoc within that isolated Python environment.
For Linux verification with the CI image:

```sh
docker run --rm \
  --mount "type=bind,source=$PWD,target=/workspace,readonly" \
  swift:6.4.0-trixie bash -euo pipefail -c '
    mkdir -p /tmp/ldtx/Packages
    cp -R /workspace/Packages/LDTXCorelibs /tmp/ldtx/Packages/LDTXCorelibs
    swift test --package-path /tmp/ldtx/Packages/LDTXCorelibs --scratch-path /tmp/corelibs-build \
      --disable-index-store -debug-info-format none --jobs "$(nproc)"
  '
```

CI disables indexing and debug-info generation for SwiftPM tests and sets
parallelism to the runner CPU count. The reusable workflow runs Corelibs on Linux.
The macOS test invocation runs the complete suite, while Corelibs also runs
separately on Linux.

## Xcode Cloud tests

After changing the LDTXApp test target list, regenerate the checked-in test
plans from the XcodeGen project and commit them:

```sh
xcodegen generate
python3 ci_scripts/generate-test-plans.py
```

The target names and shard plan settings are defined in
`ci_scripts/generate-test-plans.py`; UI suites declare their shard in the test
sources. Run the script with `--check` to verify the plans without modifying them.

Select the shared `LDTXApp` scheme for the Xcode Cloud test workflow, using
`Debug`. It runs the complete test suite.
The macOS-only `LDTXOutputTests` scheme runs output configuration, media delivery,
and recording/streaming service tests in one hostless bundle.
Easy, Medium, and Hard share the hostless `LDTXModuleTests` bundle. Their suites
carry `.easy`, `.medium`, and `.hard` Swift Testing tags for classification;
the standard test invocation runs all of them.
It does not launch `LDTXApp` or use XCUI automation. Keep archive workflows on
`LDTXApp` with `Distribution`.

Build the shared test bundle locally with:

```sh
xcodegen generate
xcodebuild \
  -project LDTX.xcodeproj \
  -scheme LDTXModuleTests \
  -destination platform=macOS \
  -derivedDataPath .derivedData \
  build-for-testing
```

Unit-test bundles run without a host application, except XpcTests, which may use
an application host to exercise its embedded XPC service. UI component tests
construct their own windows and hosted SwiftUI views.

### Real OCR recognition

The real-recognition suites `WorkspaceClockOCRIntegrationTestSuite` and
`ManualOCRRecognitionIntegrationTestSuite` remain enabled for local testing and
Xcode Cloud. GitHub Actions skips only these two suites because its hosted arm64
runner cannot execute Vision OCR; deterministic OCR configuration and service
integration tests continue to run there. Keep the real-recognition suites tagged
`.hard` to describe their framework requirements.

Run the manual OCR recognition test locally:

```sh
xcodebuild -project LDTX.xcodeproj -scheme LDTXModuleTests \
  -destination platform=macOS -derivedDataPath .derivedData \
  -only-testing:LDTXModuleTests/ManualOCRRecognitionIntegrationTestSuite test
```

## Generated Files

Prefer changing the source of truth, then regenerate the generated output with
the commands below.

| Generated output                                      | Source of truth                                  |
| ----------------------------------------------------- | ------------------------------------------------ |
| `LDTX.xcodeproj`                                      | `project.yml`                                    |
| `Packages/LDTXCorelibs/Sources/LDTXMessages/Messages/generated/*.pb.swift` | `Protos/*.proto` |
| `Packages/LDTXCorelibs/Sources/LDTXNanopbGenerated/generated/*.pb.h`, `*.pb.c` | `Protos/*.proto` via the official nanopb generator |
| `Resources/LDTX/MediaPipeSelfieSegmenter.mlpackage` | `Tools/MediaPipeLandscapeCoreML/MediaPipeSelfieSegmenter.py`              |

The Workspace v4 schema is split across `Protos/workspace_v4_*.proto`.
The nanopb `.pb.c` files supply the descriptor definitions and compile directly
in `LDTXNanopbGenerated`.
All schemas under `Protos` use Edition 2024. The generators use the pinned
`grpcio-tools` package to compile schemas and create a FileDescriptorSet, then
the Python generator in
[the ldtx-protoc-gen skill](../.agents/skills/ldtx-protoc-gen/SKILL.md) to generate
Swift models and adapters. Generate C headers and sources separately with the
vendored nanopb generator and `Protos/*.options`, following the skill's commands.
The Swift generator compiles schemas through `grpcio-tools` and reads the resulting
descriptor using Python protobuf. Neither generator requires a standalone protoc
binary. The app uses the vendored nanopb runtime; no generator runs
during normal builds. Singular
fields use the edition default of explicit presence; do not set file-level
`IMPLICIT` presence.
The `uses_24_hour_time` field retains its existing name with a field-level
legacy naming-style override.

`Protos/envelope.proto` defines the separate persistence envelopes. They are
documented at `docs/protos/workspace.html`.

```sh
pipx run --no-cache --backend pip --path .agents/skills/ldtx-protoc-gen/scripts/ldtx-protoc-gen-swift.py
pipx run --no-cache --backend pip --path .agents/skills/ldtx-protoc-gen/scripts/ldtx-protoc-gen-swift.py --check
```

**Regenerate the Workspace v4 reference:**

```sh
node docs/_BUILD.mjs protos
```

**Build the GitHub Pages distribution, including behavior scenarios:**

```sh
node docs/_BUILD.mjs dist
```

Write English Gherkin cases in `docs/scenarios/` following the
[naming and tagging rules](scenarios/README.md).
The build emits a stable `docs/dist/scenarios/UCT-1000/index.html` URL
independently of the component and description in the filename.

The HTML embeds escaped source in a `<pre>` inside `<gherkin-scenario>`.
The Custom Element parses the source in the browser using the fixed
`@cucumber/gherkin@42.0.1` CDN bundle and renders the behavior description.
The original source remains readable when JavaScript or the CDN is unavailable.
These pages describe behavior; they do not execute tests or report test results.

The generator updates checked-in sources using `apply_patch` (required on PATH).
`--check` verifies reproducibility of Swift sources without writing files.
Regenerate C headers separately into a temporary directory and compare them
with the checked-in headers. If `--descriptor` is supplied, it is used directly;
otherwise the tool compiles schemas with `grpcio-tools`. Generated models retain explicit presence and
fixed schema defaults. The official pb_decode path fills an owned C message,
which is copied into the Swift model before pb_release frees its allocations.
Encoding copies into C storage and uses pb_encode, then releases that storage.
Unknown fields are discarded. Strings use length-delimited C bytes storage to
preserve embedded NULs; copying into Swift rejects invalid UTF-8. No field
callbacks or preliminary wire-type scan are used. Map output is ordered
by key. The Swift Clang importer uses the same three configuration macros as the
upstream nanopb package.

YouTube output IPC uses Codable models encoded as binary PropertyLists. It has
no protobuf schema or Corelibs dependency; protocol version 9 identifies this
wire format. Update both app and embedded XPC service together.

**If the MediaPipe Selfie Segmenter model must be updated:**

The converter uses the fixed Hugging Face revision in
[`Tools/MediaPipeLandscapeCoreML/MediaPipeSelfieSegmenter.py`](../Tools/MediaPipeLandscapeCoreML/MediaPipeSelfieSegmenter.py).
Change that revision deliberately and review the regenerated model together
with the dependency pins in [`Tools/MediaPipeLandscapeCoreML/requirements.txt`](../Tools/MediaPipeLandscapeCoreML/requirements.txt).
The generated resource stays at `Resources/LDTX/MediaPipeSelfieSegmenter.mlpackage`
for the app build. The converter resolves that path relative to its own file,
independently of the current working directory. From the repository root, enter
the tooling directory and install the pinned source requirements:

```sh
cd Tools/MediaPipeLandscapeCoreML
uv venv --python 3.13.13
uv pip install -r requirements.txt
```

Run the converter from that same tooling directory:

```sh
uv run --no-sync python MediaPipeSelfieSegmenter.py
cd ../..
```

**If the Xcode project must be updated:**

```sh
xcodegen generate
```

**Build the standalone `ldtx` CLI:**

The standalone CLI is an XcodeGen-managed command-line target. It contains only
recording and workspace file operations. Corelibs are supplied by the local package.

```sh
xcodegen generate
xcodebuild -project LDTX.xcodeproj -scheme ldtx -configuration Release \
  -destination platform=macOS -derivedDataPath .derivedData build
.derivedData/Build/Products/Release/ldtx --help
```

Other app-side modules and the helper remain XcodeGen targets. The CLI tests
remain in an isolated hostless LDTXUtilsTests bundle because they redirect process
stdout/stderr and mutate environment variables. macOS protobuf-extra tests run in
the shared LDTXModuleTests target with Medium tags.

## Recording CLI

Run the standalone CLI from the Xcode build directory:

```sh
.derivedData/Build/Products/Release/ldtx record --help
.derivedData/Build/Products/Release/ldtx workspace --help
```

The app-bundled `LDTXHelper` has the additional `app` and `mcp` surfaces. Its
MCP server is reserved for App Automation; file operations remain in the
standalone CLI.

**Test the LDTX library if needed:**

See [`testing.md`](testing.md) for the PTS regression policy and the cases that
must be retained when changing timing or media pipelines.

```sh
swift test --package-path Packages/LDTXCorelibs
```

**Test macOS modules if needed:**

```sh
xcodebuild -project LDTX.xcodeproj -scheme LDTXModuleTests \
  -destination platform=macOS -derivedDataPath .derivedData test
```

**Build the LDTX app if needed:**

```sh
xcodebuild \
  -project LDTX.xcodeproj \
  -scheme LDTXApp \
  -destination platform=macOS \
  -derivedDataPath .derivedData \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build
```

**Build the LDTX app for unit testing if needed:**

```sh
xcodebuild \
  -project LDTX.xcodeproj \
  -scheme LDTXApp \
  -destination platform=macOS \
  -derivedDataPath .derivedData \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build-for-testing
```

**Run the package and app integration tests if needed:**

```sh
swift test --package-path Packages/LDTXCorelibs

xcodebuild \
  -project LDTX.xcodeproj \
  -scheme LDTXApp \
  -configuration Debug \
  -destination platform=macOS \
  -derivedDataPath .derivedData \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build-for-testing

xcodebuild \
  -project LDTX.xcodeproj \
  -scheme LDTXApp \
  -configuration Debug \
  -destination platform=macOS \
  -derivedDataPath .derivedData \
  COMPILER_INDEX_STORE_ENABLE=NO \
  test-without-building
```

**Checks for this repository if needed:**

GitHub Actions is the pull-request merge gate: Swift package tests run in
parallel with the hosted `LDTX` integration test. The `LDTX`
application, Vision, and Quick Look archive are built and signed by Xcode
Cloud, which is the release build authority. Its separate Test action runs the
hostless framework tests using the `LDTXModuleTests` scheme.

```sh
bin/check
```

## Public-log privacy regression

After building the `LDTXModuleTests` and `LDTXOutputTests` suites, run:

```sh
Tools/Regression/public-log-privacy.sh
```

An optional argument selects the absolute Debug products directory. Run outside
an agent sandbox, following `AGENTS.md`. The probe calls production duplicate-step
normalization and a mock-only DASH transport failure with distinctive private
names, an error domain, a path and OCR-like text. It checks ordinary unified-log
collection for both expected events, the public count/error code, and absence of
the fixtures. It does not contact the network or use capture devices or recordings.

Xcode's test runner can collect private values, so its logs are not a substitute
for this ordinary-process check. This focused probe does not establish privacy
for every app flow, shipped builds, or log retention. Recording creation, playback,
Quick Look and Workspace close still need separate runtime coverage when safe.
