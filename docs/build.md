<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Build Guide

**Set up Protobuf tools when needed:**

```sh
brew install protobuf swift-protobuf
```

## Generated Files

Prefer changing the source of truth, then regenerate the generated output with
the commands below.

| Generated output                                      | Source of truth                                  |
| ----------------------------------------------------- | ------------------------------------------------ |
| `LDTX.xcodeproj`                                      | `project.yml`                                    |
| `Sources/LDTXProgram/persistence.pb.swift`            | `Protos/persistence.proto`                        |
| `Sources/LDTXProgram/program.pb.swift`                | `Protos/program.proto`                            |
| `Sources/LDTXWorkspace/app_settings.pb.swift`         | `Protos/app_settings.proto`                       |
| `Sources/LDTXWorkspace/envelope.pb.swift`             | `Protos/envelope.proto`                            |
| `Sources/LDTXWorkspace/workspace_v4_*.pb.swift`       | `Protos/workspace_v4_*.proto`                      |
| `Resources/LDTX/MediaPipeSelfieSegmenter.mlpackage` | `Tools/MediaPipeSelfieSegmenter.py`              |

**If a Program schema under `Protos/` changes:**

```sh
protoc \
  --proto_path=Protos \
  --plugin=protoc-gen-swift="$(brew --prefix swift-protobuf)/bin/protoc-gen-swift" \
  --swift_opt=Visibility=Public \
  --swift_opt=FileNaming=DropPath \
  --swift_out=Sources/LDTXProgram \
  Protos/program.proto \
  Protos/persistence.proto
```

The Workspace v4 schema is split across `Protos/workspace_v4_*.proto`.
`Protos/envelope.proto` defines the separate persistence envelopes. They are
documented at `docs/protos/workspace.html`.

```sh
protoc \
  --proto_path=Protos \
  --plugin=protoc-gen-swift="$(brew --prefix swift-protobuf)/bin/protoc-gen-swift" \
  --swift_opt=ProtoPathModuleMappings=Protos/module_mappings.asciipb \
  --swift_opt=Visibility=Public \
  --swift_opt=FileNaming=DropPath \
  --swift_out=Sources/LDTXWorkspace \
  Protos/app_settings.proto \
  Protos/envelope.proto \
  Protos/workspace_v4_definition.proto \
  Protos/workspace_v4_input_device.proto \
  Protos/workspace_v4_preferences.proto \
  Protos/workspace_v4_vfx.proto \
  Protos/workspace_v4_video_component.proto \
  Protos/workspace_v4_vision.proto
```

**Regenerate the Workspace v4 reference:**

```sh
node docs/_BUILD.mjs protos
```

**If `Protos/youtube_output.proto` changes:**

```sh
protoc \
  --proto_path=Protos \
  --plugin=protoc-gen-swift="$(brew --prefix swift-protobuf)/bin/protoc-gen-swift" \
  --swift_opt=Visibility=Public \
  --swift_opt=FileNaming=DropPath \
  --swift_out=Sources/LDTXYouTubeOutputProtocol \
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
swift build -c release --target LDTXWorkspace
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
swift test --filter LDTXWorkspaceEasyTests
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
  -scheme LDTX \
  -destination platform=macOS \
  -derivedDataPath .derivedData \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build
```

**Build the LDTX app for unit testing if needed:**

```sh
xcodebuild \
  -project LDTX.xcodeproj \
  -scheme LDTX \
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
  -scheme LDTX \
  -configuration CI \
  -destination platform=macOS \
  -derivedDataPath .derivedData \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build-for-testing

xcodebuild \
  -project LDTX.xcodeproj \
  -scheme LDTX \
  -configuration CI \
  -destination platform=macOS \
  -derivedDataPath .derivedData \
  COMPILER_INDEX_STORE_ENABLE=NO \
  test-without-building
```

**Checks for this repository if needed:**

GitHub Actions is the pull-request merge gate: Swift package tests run in
parallel with the hosted `LDTX` integration test. The `LDTX`
application, Vision, and Quick Look archive are built and signed by Xcode
Cloud, which is the release build authority and does not run tests.

```sh
reuse --no-multiprocessing lint
swift format lint --recursive .
git ls-files '*.cpp' '*.hpp' | xargs clang-format --dry-run --Werror
```
