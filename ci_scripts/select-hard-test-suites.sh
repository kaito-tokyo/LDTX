#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Prints one SwiftPM --filter value per selected Hard suite.  Paths are read
# from arguments, one per line, so callers may use either a PR diff or fixtures.
modules=(LDTXAppCore LDTXBackgroundSegmentation LDTXMP4 LDTXProgram LDTXProgramRuntime LDTXVideoRendering)

suites_for_module() {
  case "$1" in
    LDTXAppCore) printf '%s\n' LDTXAppCoreTests.PaneSplitViewTests LDTXAppCoreTests.WindowLifecycleTests ;;
    LDTXBackgroundSegmentation) printf '%s\n' LDTXBackgroundSegmentationTests.BackgroundRemovalInferenceGateTests ;;
    LDTXMP4) printf '%s\n' LDTXMP4Tests.H264VideoEncoderTests ;;
    LDTXProgram) printf '%s\n' LDTXProgramTests.ProgramRenderingOrderTests ;;
    LDTXProgramRuntime) printf '%s\n' LDTXProgramRuntimeTests.AudioSideStreamSegmentPipelineTests LDTXProgramRuntimeTests.ClockOverlayRuntimeTests LDTXProgramRuntimeTests.VideoInputPreprocessingTests LDTXProgramRuntimeTests.YouTubeOutputMediaSampleConverterTests LDTXProgramRuntimeTests.YouTubeRTMPSWorkspaceServiceTests ;;
    LDTXVideoRendering) printf '%s\n' LDTXVideoRenderingTests.VideoCompositorTests ;;
  esac
}

common_change=false
selected_modules=' '
for path in "$@"; do
  case "$path" in
    Package.swift|Package.resolved|project.yml|.github/workflows/*|ci_scripts/*|.github/actions/*)
      common_change=true ;;
  esac
  for module in "${modules[@]}"; do
    if [[ "$path" == "Sources/$module/"* || "$path" == "Tests/${module}Tests/"* ||
      ( "$module" == LDTXAppCore && "$path" == Tests/LDTXAppTests/* ) ]]; then
      selected_modules+="$module "
    fi
  done
done

if "$common_change"; then
  selected_modules=" ${modules[*]} "
fi

for module in "${modules[@]}"; do
  [[ "$selected_modules" == *" $module "* ]] || continue
  suites_for_module "$module"
done | LC_ALL=C sort
