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

`Packages/LDTXCorelibs/Package.swift` defines one Swift target, `LDTXCorelibs`,
and its C implementation dependency, `LDTXNanopbGenerated`. Sources live under
`Packages/LDTXCorelibs/Sources/<target>`. There is no repository-root manifest.
Swift code is organized into `Messages`, `Values`, `Program`, `Nanopb`,
`WorkspaceBundleFormat`, and `RecordBundleFormat` directories.
`Messages` is reserved for Protobuf and its handwritten extensions.
See [target dependencies](target-dependencies.md) for their boundaries and
Workspace UI's presentation contracts.

XcodeGen references the local package's dynamic `LDTXCorelibs` product, and all
Swift consumers use `import LDTXCorelibs`. One dynamic product provides a single
implementation across the application's framework graph. The official nanopb
package and generated C target remain implementation dependencies. Keep Swift's
C importer macros aligned with the C targets. AVFoundation operations remain in
LDTXRecording outside Corelibs.

On Linux, files that only use Foundation's Swift value APIs import
FoundationEssentials. Files using compatibility APIs such as JSONSerialization,
NSNumber, NSNull, PropertyListSerialization, and XMLParser retain Foundation.
Apple platforms use the SDK's Foundation module. Pure Swift values need neither.

Tests live in `Packages/LDTXCorelibs/Tests/<module>Tests` and are defined once as
SwiftPM's `LDTXCorelibsTests`. `project/corelibs.yml` and the Xcode test plans
reference that package target directly; XcodeGen does not create another test
bundle or source group.

```sh
git submodule update --init Vendors/nanopb
swift build --package-path Packages/LDTXCorelibs
swift test --package-path Packages/LDTXCorelibs
```

GitHub Codespaces uses `.devcontainer/devcontainer.json`, which initializes the
nanopb submodule and resolves this package. Python and protoc are needed only
when regenerating message sources.
For Linux verification with the CI image:

```sh
docker run --rm \
  --mount "type=bind,source=$PWD,target=/workspace,readonly" \
  swift:6.4.0-trixie bash -euo pipefail -c '
    mkdir -p /tmp/ldtx/Packages /tmp/ldtx/Vendors
    cp -R /workspace/Packages/LDTXCorelibs /tmp/ldtx/Packages/LDTXCorelibs
    cp -R /workspace/Vendors/nanopb /tmp/ldtx/Vendors/nanopb
    swift test --package-path /tmp/ldtx/Packages/LDTXCorelibs --scratch-path /tmp/corelibs-build \
      --disable-index-store -debug-info-format none --jobs "$(nproc)"
  '
```

CI disables indexing and debug-info generation for SwiftPM tests and sets
parallelism to the runner CPU count. The reusable workflow runs Corelibs on Linux.
The macOS `pr` plan omits Corelibs; `push-main` includes them. Both plans include
the isolated CLI tests, while macOS protobuf-extra tests run in LDTXModuleTests.

## Xcode Cloud tests

Select the shared `LDTXApp` scheme and `LDTXTests` plan for the Xcode Cloud
test workflow, using `Debug`. The plan includes Easy, Medium, Hard, and Output tests.
The macOS-only `LDTXOutputTests` scheme runs output configuration, media delivery,
and recording/streaming service tests in one hostless bundle.
Easy, Medium, and Hard share the hostless `LDTXModuleTests` bundle. Their suites
carry `.easy`, `.medium`, and `.hard` Swift Testing tags. Select the `Easy`,
`Medium`, or `Hard` test plan from the `LDTXModuleTests` scheme. `Easy` is the
default plan; use `-testPlan` to select a plan on the command line.
It does not launch `LDTXApp` or use XCUI automation. Keep archive workflows on
`LDTXApp` with `Distribution`.

Build the shared test bundle locally with:

```sh
xcodegen generate
xcodebuild \
  -project LDTX.xcodeproj \
  -scheme LDTXModuleTests -testPlan Hard \
  -destination platform=macOS \
  -derivedDataPath .derivedData \
  build-for-testing
```

XCUI automation belongs only in `LDTXAppUITests`. Unit-test bundles run without
a host application, except XpcTests, which may use an application host to
exercise its embedded XPC service.

### Real OCR on hosted runners

GitHub Actions excludes `WorkspaceClockOCRIntegrationTestSuite` and
`ManualOCRRecognitionIntegrationTestSuite` from its shared macOS test invocation
for both pull requests and pushes to `main`.
The hosted arm64 VM can fail Vision text recognition with E5RT error 11 and
`No available backends on platform [universal] for compute units ane`.
These exclusions are not successful recognition tests. Keep the real recognition
suite tagged `.hard` and run it locally on a supported Mac; it remains included in
local test plans and Xcode Cloud's `Hard` plan selection. The deterministic manual
OCR control, error/retry, UI, variable publication, and recording persistence
tests remain enabled in GitHub Actions.

Run the manual OCR recognition test locally without the CI exclusions:

```sh
xcodebuild -project LDTX.xcodeproj -scheme LDTXModuleTests -testPlan Hard \
  -destination platform=macOS -derivedDataPath .derivedData \
  -only-testing:LDTXModuleTests/ManualOCRRecognitionIntegrationTestSuite test
```

## Generated Files

Prefer changing the source of truth, then regenerate the generated output with
the commands below.

| Generated output                                      | Source of truth                                  |
| ----------------------------------------------------- | ------------------------------------------------ |
| `LDTX.xcodeproj`                                      | `project.yml`                                    |
| `Packages/LDTXCorelibs/Sources/LDTXCorelibs/Messages/envelope.pb.swift` | `Protos/envelope.proto` |
| `Packages/LDTXCorelibs/Sources/LDTXCorelibs/Messages/workspace_v4_*.pb.swift` | `Protos/workspace_v4_*.proto` |
| `Packages/LDTXCorelibs/Sources/LDTXNanopbGenerated/*.pb.c`, `include/*.pb.h` | `Protos/*.proto` via the official nanopb generator |
| `Packages/LDTXCorelibs/Sources/LDTXNanopbGenerated/StorageChecks.c` | Message descriptors and callback-only storage policy |
| `Resources/LDTX/MediaPipeSelfieSegmenter.mlpackage` | `Tools/MediaPipeLandscapeCoreML/MediaPipeSelfieSegmenter.py`              |

The Workspace v4 schema is split across `Protos/workspace_v4_*.proto`.
All schemas under `Protos` use Edition 2024. Run protoc 36.2 externally to create
a FileDescriptorSet, then use the Python generator in
[`Tools/GenerateNanopbProtos`](../Tools/GenerateNanopbProtos/README.md) to generate
Swift models and callback-only C definitions. The tool reads descriptors using
Python protobuf, delegates C generation to the official nanopb generator, and
generates the Swift adapters. The app uses
the official nanopb SwiftPM package at runtime; no generator runs during normal builds. Singular
fields use the edition default of explicit presence; do not set file-level
`IMPLICIT` presence.
The `uses_24_hour_time` field retains its existing name with a field-level
legacy naming-style override.

`Protos/envelope.proto` defines the separate persistence envelopes. They are
documented at `docs/protos/workspace.html`.

```sh
git submodule update --init Vendors/nanopb
mkdir -p /tmp/ldtx-proto-input
protoc -I Protos --include_imports --include_source_info \
  --descriptor_set_out=/tmp/ldtx-proto-input/schemas.pb Protos/*.proto
protoc -I Vendors/nanopb/generator/proto \
  --python_out=/tmp/ldtx-proto-input nanopb.proto
pipx run --backend pip --path Tools/GenerateNanopbProtos/generate.py \
  --descriptor /tmp/ldtx-proto-input/schemas.pb
pipx run --backend pip --path Tools/GenerateNanopbProtos/generate.py \
  --descriptor /tmp/ldtx-proto-input/schemas.pb --check
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
`--check` verifies reproducibility of C and Swift sources without
writing files. The descriptor input is supplied explicitly with `--descriptor`;
the tool never invokes protoc. Generated models retain explicit presence and
fixed schema defaults. The official pb_encode/pb_decode path uses field callbacks;
C structs hold only context pointers, not copies of the Swift payloads. Unknown
fields are discarded. String decoding fills Swift String's
initialization buffer directly and rejects invalid UTF-8. Map output is ordered
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
xcodebuild -project LDTX.xcodeproj -scheme LDTXModuleTests -testPlan Easy \
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
  -testPlan Default \
  -configuration Debug \
  -destination platform=macOS \
  -derivedDataPath .derivedData \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build-for-testing

xcodebuild \
  -project LDTX.xcodeproj \
  -scheme LDTXApp \
  -testPlan Default \
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
hostless framework tests using the `LDTXModuleTests` scheme and `Hard` plan.

```sh
bin/check
```

## Public-log privacy regression

After building the `Hard` plan of `LDTXModuleTests` and the `LDTXOutputTests` suite, run:

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
