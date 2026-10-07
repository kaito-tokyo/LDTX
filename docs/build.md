<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Build Guide

**Set up Protobuf tools when needed:**

```sh
brew install protobuf swift-protobuf
```

## Corelibs

Linux-compatible modules live in `Sources/Corelibs/<module>`.
XcodeGen builds these sources directly as framework targets; the Xcode project
has no dependency on a local Swift package. SwiftPM builds the same sources
independently. On Linux, the root package includes only Corelibs and their tests;
on macOS, it also includes the existing CLI targets.

Recording bundle IO and DASH parsing live in `LDTXRecordBundleFormat`;
AVFoundation media operations remain in `LDTXRecording`.

Tests live in `Tests/Corelibs/<module>Tests`. XcodeGen and SwiftPM both
include them in the `LDTXCorelibsTests` target.

Verify the Linux build and tests with the same image used by CI:

```sh
docker run --rm \
  --mount "type=bind,source=$PWD,target=/workspace,readonly" \
  swift:6.4.0-trixie bash -euo pipefail -c '
    mkdir -p /tmp/package/Sources /tmp/package/Tests
    cp /workspace/Package.swift /workspace/Package.resolved /tmp/package/
    cp -R /workspace/Sources/Corelibs /tmp/package/Sources/
    cp -R /workspace/Tests/Corelibs /tmp/package/Tests/
    cd /tmp/package
    swift test --disable-index-store -debug-info-format none --jobs "$(nproc)"
  '
```

CI disables indexing and debug-info generation for SwiftPM tests and sets build
parallelism to the runner CPU count. Debug-info generation remains available
for local debugging by omitting `-debug-info-format none`.

The reusable Xcode workflow runs Corelibs on Linux alongside the single macOS
`golden_gate` job. Pull requests run Corelibs tests only on Linux. Pushes to
`main` also run Corelibs tests on macOS. The macOS job selects the `pr` test
plan for pull requests and the `push-main` plan for pushes to `main`. Both plans
include Easy, Medium, Hard, Output, UI component, UI automation, and XPC tests; only
`push-main` includes Corelibs tests.

## Xcode Cloud tests

Select the shared `LDTXApp` scheme and `LDTXTests` plan for the Xcode Cloud
test workflow, using `Debug`. The plan includes Easy, Medium, Hard, and Output tests.
The macOS-only `LDTXOutputTests` scheme runs output configuration, media delivery,
and recording/streaming service tests in one hostless bundle.
The dedicated `LDTXHardTests` scheme runs only HardTests directly. HardTests is a
hostless unit-test bundle for Vision, VideoToolbox, CoreML, Metal, and
AVFoundation tests.
It does not launch `LDTXApp` or use XCUI automation. Keep archive workflows on
`LDTXApp` with `Distribution`.

Build this test bundle locally with:

```sh
xcodegen generate
xcodebuild \
  -project LDTX.xcodeproj \
  -scheme LDTXHardTests \
  -destination platform=macOS \
  -derivedDataPath .derivedData \
  build-for-testing
```

XCUI automation belongs only in `LDTXAppUITests`. Unit-test bundles run without
a host application, except XpcTests, which may use an application host to
exercise its embedded XPC service.

## Generated Files

Prefer changing the source of truth, then regenerate the generated output with
the commands below.

| Generated output                                      | Source of truth                                  |
| ----------------------------------------------------- | ------------------------------------------------ |
| `LDTX.xcodeproj`                                      | `project.yml`                                    |
| `Sources/Corelibs/LDTXProtos/envelope.pb.swift`             | `Protos/envelope.proto`                            |
| `Sources/Corelibs/LDTXProtos/youtube_output.pb.swift`      | `Protos/youtube_output.proto`                     |
| `Sources/Corelibs/LDTXProtos/workspace_v4_*.pb.swift`       | `Protos/workspace_v4_*.proto`                      |
| `Resources/LDTX/MediaPipeSelfieSegmenter.mlpackage` | `Tools/MediaPipeSelfieSegmenter.py`              |

The Workspace v4 schema is split across `Protos/workspace_v4_*.proto`.
`Protos/envelope.proto` defines the separate persistence envelopes. They are
documented at `docs/protos/workspace.html`.

```sh
protoc \
  --proto_path=Protos \
  --plugin=protoc-gen-swift="$(brew --prefix swift-protobuf)/bin/protoc-gen-swift" \
  --swift_opt=Visibility=Public \
  --swift_opt=FileNaming=DropPath \
  --swift_out=Sources/Corelibs/LDTXProtos \
  Protos/envelope.proto \
  Protos/workspace_v4_definition.proto \
  Protos/workspace_v4_input_device.proto \
  Protos/workspace_v4_preferences.proto \
  Protos/workspace_v4_vfx.proto \
  Protos/workspace_v4_video_component.proto \
  Protos/workspace_v4_vision.proto \
  Protos/workspace_v4_types.proto
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

**If `Protos/youtube_output.proto` changes:**

```sh
protoc \
  --proto_path=Protos \
  --plugin=protoc-gen-swift="$(brew --prefix swift-protobuf)/bin/protoc-gen-swift" \
  --swift_opt=Visibility=Public \
  --swift_opt=FileNaming=DropPath \
  --swift_out=Sources/Corelibs/LDTXProtos \
  Protos/youtube_output.proto
```

**If the MediaPipe Selfie Segmenter model must be updated:**

The converter uses the fixed Hugging Face revision in
[`Tools/MediaPipeSelfieSegmenter.py`](../Tools/MediaPipeSelfieSegmenter.py).
Change that revision deliberately and review the regenerated model together
with the dependency pins in [`requirements-dev.txt`](../requirements-dev.txt).
Install the reviewed transitive dependency set from the hash-locked file:

```sh
uv venv --python 3.13
uv pip sync --require-hashes requirements-dev.lock
```

After deliberately changing a source dependency, regenerate the lock with:

```sh
uv pip compile --generate-hashes --python-version 3.13 \
  requirements-dev.txt --output-file requirements-dev.lock
```

```sh
uv run --no-sync python Tools/MediaPipeSelfieSegmenter.py
```

**If the Xcode project must be updated:**

```sh
xcodegen generate
```

**Build the standalone `ldtx` CLI:**

The standalone CLI is defined by `Package.swift` independently from the
XcodeGen project. It contains only recording and workspace file operations.

```sh
swift package resolve
swift build -c release --product ldtx
"$(swift build -c release --show-bin-path)/ldtx" --help
```

The Xcode project does not read or generate `Package.swift`.

The app-side modules are built by Xcode from `project.yml`. The standalone
SwiftPM package intentionally defines only the file-operation dependency graph:

```sh
swift build -c release --target LDTXRecording
swift build -c release --target LDTXProgram
swift build -c release --target LDTXWorkspaceAppletModel
swift build -c release --target LDTXWorkspaceAppletStore
swift build -c release --target LDTXWorkspaceAppletService
```

## Recording CLI

Run the standalone CLI from the SwiftPM build directory:

```sh
"$(swift build -c release --show-bin-path)/ldtx" record --help
"$(swift build -c release --show-bin-path)/ldtx" workspace --help
```

The app-bundled `LDTXHelper` has the additional `app` and `mcp` surfaces. Its
MCP server is reserved for App Automation; file operations remain in the
standalone CLI.

**Test the LDTX library if needed:**

See [`testing.md`](testing.md) for the PTS regression policy and the cases that
must be retained when changing timing or media pipelines.

```sh
swift test
```

**Test Swift modules if needed:**

```sh
swift test --filter LDTXProgramEasyTests
swift test --filter LDTXDashEasyTests
swift test --filter LDTXYouTubeEasyTests
swift test --filter LDTXMediaTimingEasyTests
swift test --filter LDTXMP4EasyTests
swift test --filter LDTXVideoRenderingHardTests
swift test --filter LDTXAudioEngineEasyTests
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
swift test

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
hostless framework tests using `LDTXHardTests`.

```sh
reuse --no-multiprocessing lint
swift format lint --recursive .
git ls-files '*.cpp' '*.hpp' | xargs clang-format --dry-run --Werror
```
