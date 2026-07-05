<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Build Guide

**Set up Protobuf tools when needed:**

```sh
swift build --product protoc
swift build --product protoc-gen-swift
```

**If a file under `Sources/LDTXAutomation/Protos` changes:**

```sh
"$(swift build --show-bin-path)/protoc" \
  --proto_path=Sources/LDTXAutomation/Protos \
  --plugin=protoc-gen-swift="$(swift build --show-bin-path)/protoc-gen-swift" \
  --swift_opt=Visibility=Public \
  --swift_opt=FileNaming=DropPath \
  --swift_out=Sources/LDTXAutomation \
  Sources/LDTXAutomation/Protos/automation.proto
```

**If a file under `Sources/LDTXProgram/Protos` changes:**

```sh
"$(swift build --show-bin-path)/protoc" \
  --proto_path=Sources/LDTXProgram/Protos \
  --plugin=protoc-gen-swift="$(swift build --show-bin-path)/protoc-gen-swift" \
  --swift_opt=Visibility=Public \
  --swift_opt=FileNaming=DropPath \
  --swift_out=Sources/LDTXProgram \
  Sources/LDTXProgram/Protos/program.proto \
  Sources/LDTXProgram/Protos/persistence.proto
```

**If a file under `Sources/LDTXWorkspace/Protos` changes:**

```sh
"$(swift build --show-bin-path)/protoc" \
  --proto_path=Sources/LDTXWorkspace/Protos \
  --proto_path=Sources/LDTXProgram/Protos \
  --plugin=protoc-gen-swift="$(swift build --show-bin-path)/protoc-gen-swift" \
  --swift_opt=ProtoPathModuleMappings=Sources/LDTXWorkspace/Protos/module_mappings.asciipb \
  --swift_opt=Visibility=Public \
  --swift_opt=FileNaming=DropPath \
  --swift_out=Sources/LDTXWorkspace \
  Sources/LDTXWorkspace/Protos/workspace.proto
```

**If the MediaPipe Selfie Segmenter model must be updated:**

```sh
python3 Tools/MediaPipeSelfieSegmenter.py
```

**If the Xcode project must be updated:**

```sh
xcodegen generate
```

**Build the LDTX library:**

```sh
swift build
```

**Test the LDTX library:**

```sh
swift test
```

**Build the LDTX app:**

```sh
xcodebuild \
  -project LDTX.xcodeproj \
  -scheme LDTX \
  -destination platform=macOS \
  -derivedDataPath .derivedData \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build
```

**Build the LDTX app for testing:**

```sh
xcodebuild \
  -project LDTX.xcodeproj \
  -scheme LDTX \
  -destination platform=macOS \
  -derivedDataPath .derivedData \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build-for-testing
```

**Test the LDTX app:**

```sh
xcodebuild \
  -project LDTX.xcodeproj \
  -scheme LDTX \
  -destination platform=macOS \
  -derivedDataPath .derivedData \
  COMPILER_INDEX_STORE_ENABLE=NO \
  test-without-building
```

**Checks for this repository:**

```sh
reuse --no-multiprocessing lint
swift format lint --recursive .
git ls-files '*.cpp' '*.hpp' | xargs clang-format --dry-run --Werror
```
