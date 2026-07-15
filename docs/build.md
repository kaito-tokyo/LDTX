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
| `Sources/LDTXAutomation/automation.pb.swift`          | `Sources/LDTXAutomation/Protos/automation.proto` |
| `Sources/LDTXProgram/persistence.pb.swift`            | `Sources/LDTXProgram/Protos/persistence.proto`   |
| `Sources/LDTXProgram/program.pb.swift`                | `Sources/LDTXProgram/Protos/program.proto`       |
| `Sources/LDTXWorkspace/workspace.pb.swift`            | `Sources/LDTXWorkspace/Protos/workspace.proto`   |
| `Sources/LDTXApp/MediaPipeSelfieSegmenter.mlpackage` | `Tools/MediaPipeSelfieSegmenter.py`              |

**If a file under `Sources/LDTXAutomation/Protos` changes:**

```sh
protoc \
  --proto_path=Sources/LDTXAutomation/Protos \
  --plugin=protoc-gen-swift="$(brew --prefix swift-protobuf)/bin/protoc-gen-swift" \
  --swift_opt=Visibility=Public \
  --swift_opt=FileNaming=DropPath \
  --swift_out=Sources/LDTXAutomation \
  Sources/LDTXAutomation/Protos/automation.proto
```

**If a file under `Sources/LDTXProgram/Protos` changes:**

```sh
protoc \
  --proto_path=Sources/LDTXProgram/Protos \
  --plugin=protoc-gen-swift="$(brew --prefix swift-protobuf)/bin/protoc-gen-swift" \
  --swift_opt=Visibility=Public \
  --swift_opt=FileNaming=DropPath \
  --swift_out=Sources/LDTXProgram \
  Sources/LDTXProgram/Protos/program.proto \
  Sources/LDTXProgram/Protos/persistence.proto
```

**If a file under `Sources/LDTXWorkspace/Protos` changes:**

```sh
protoc \
  --proto_path=Sources/LDTXWorkspace/Protos \
  --proto_path=Sources/LDTXProgram/Protos \
  --plugin=protoc-gen-swift="$(brew --prefix swift-protobuf)/bin/protoc-gen-swift" \
  --swift_opt=ProtoPathModuleMappings=Sources/LDTXWorkspace/Protos/module_mappings.asciipb \
  --swift_opt=Visibility=Public \
  --swift_opt=FileNaming=DropPath \
  --swift_out=Sources/LDTXWorkspace \
  Sources/LDTXWorkspace/Protos/workspace.proto
```

**If `Sources/LDTXYouTubeOutputProtocol/Protos/youtube_output.proto` changes:**

```sh
protoc \
  --proto_path=Sources/LDTXYouTubeOutputProtocol/Protos \
  --plugin=protoc-gen-swift="$(brew --prefix swift-protobuf)/bin/protoc-gen-swift" \
  --swift_opt=Visibility=Public \
  --swift_opt=FileNaming=DropPath \
  --swift_out=Sources/LDTXYouTubeOutputProtocol \
  Sources/LDTXYouTubeOutputProtocol/Protos/youtube_output.proto
```

**If the MediaPipe Selfie Segmenter model must be updated:**

```sh
python3 Tools/MediaPipeSelfieSegmenter.py
```

**If the Xcode project must be updated:**

```sh
xcodegen generate
```

**Build the LDTX library if needed:**

```sh
swift build
```

**Build Swift modules if needed:**

```sh
swift build --target LDTXProgram
swift build --target LDTXWorkspace
swift build --target LDTXDash
swift build --target LDTXYouTube
swift build --target LDTXCapture
swift build --target LDTXMediaTiming
swift build --target LDTXMP4
swift build --target LDTXVideoComposition
swift build --target LDTXVideoRendering
swift build --target LDTXBackgroundSegmentation
swift build --target LDTXProgramRendering
swift build --target LDTXProgramRuntime
swift build --target LDTXVision
swift build --target LDTXAutomation
swift build --target LDTXAudioEngine
```

**Test the LDTX library if needed:**

See [`testing.md`](testing.md) for the PTS regression policy and the cases that
must be retained when changing timing or media pipelines.

```sh
swift test
```

**Test Swift modules if needed:**

```sh
swift test --filter LDTXProgramTests
swift test --filter LDTXWorkspaceTests
swift test --filter LDTXDashTests
swift test --filter LDTXYouTubeTests
swift test --filter LDTXMediaTimingTests
swift test --filter LDTXMP4Tests
swift test --filter LDTXVideoRenderingTests
swift test --filter LDTXAudioEngineTests
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

**Run the LDTX app unit tests if needed:**

```sh
xcodebuild \
  -project LDTX.xcodeproj \
  -scheme LDTX \
  -destination platform=macOS \
  -derivedDataPath .derivedData \
  COMPILER_INDEX_STORE_ENABLE=NO \
  test-without-building
```

**Checks for this repository if needed:**

```sh
reuse --no-multiprocessing lint
swift format lint --recursive .
git ls-files '*.cpp' '*.hpp' | xargs clang-format --dry-run --Werror
```
