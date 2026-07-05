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

**Release DMG workflow secrets:**

Xcode Cloud dispatches the GitHub Actions release workflow from
`ci_scripts/ci_post_xcodebuild.sh` when it archives a tag build. The release
workflow expects the Xcode Cloud archive action to export a Developer ID-signed
artifact, then creates, notarizes, staples, and uploads the DMG in GitHub
Actions. Configure these Xcode Cloud secret environment variables:

```text
GH_APP_ID
GH_APP_INSTALLATION_ID
GH_APP_PRIVATE_KEY_BASE64
```

Configure these GitHub Actions secrets so the release workflow can download the
Xcode Cloud artifact and notarize the final DMG:

```text
APP_STORE_CONNECT_ISSUER
APP_STORE_CONNECT_KEY
APP_STORE_CONNECT_KEY_ID
```
