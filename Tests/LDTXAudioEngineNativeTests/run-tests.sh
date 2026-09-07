#!/bin/sh
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
# SPDX-License-Identifier: Apache-2.0
set -eu
cd "$(dirname "$0")/../.."
audio_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ldtx-native-audio.XXXXXX")
trap 'rm -rf "$audio_test_dir"' EXIT
xcrun clang++ -std=c++20 -g -fsanitize=thread \
  -I Sources/LDTXAudioEngine/include -I Sources/LDTXAudioEngine \
  Sources/LDTXAudioEngine/AudioMixEngine.cpp \
  Sources/LDTXAudioEngine/WorkspaceAudioEngine.cpp \
  Tests/LDTXAudioEngineNativeTests/AudioEngineTests.cpp \
  -framework AudioToolbox -framework CoreAudio -framework CoreMedia -framework CoreFoundation \
  -o "$audio_test_dir/tests"
"$audio_test_dir/tests"
