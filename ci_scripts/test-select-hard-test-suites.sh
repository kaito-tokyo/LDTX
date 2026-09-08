#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
assert_output() {
  local expected=$1
  shift
  local actual
  actual=$("$script_dir/select-hard-test-suites.sh" "$@")
  [[ "$actual" == "$expected" ]]
}

assert_output 'LDTXMP4Tests.H264VideoEncoderTests' Sources/LDTXMP4/MP4TimingBox.swift
assert_output $'LDTXMP4Tests.H264VideoEncoderTests\nLDTXVideoRenderingTests.VideoCompositorTests' \
  Tests/LDTXMP4Tests/Easy/MP4TimingBoxTests.swift Sources/LDTXVideoRendering/VideoCompositor.swift
assert_output $'LDTXAppCoreTests.PaneSplitViewTests\nLDTXAppCoreTests.WindowLifecycleTests' Tests/LDTXAppTests/Hard/WindowLifecycleTests.swift
all=$("$script_dir/select-hard-test-suites.sh" Package.swift)
[[ $(printf '%s\n' "$all" | wc -l | tr -d ' ') == 7 ]]
[[ -z $("$script_dir/select-hard-test-suites.sh" README.md) ]]
