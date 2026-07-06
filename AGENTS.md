<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# AGENTS.md

Please read README.md and CONTRIBUTING.md first.
Use xcodegen to change the Xcode project. Do not edit the xcodeproj directly.
Use .derivedData for -derivedDataPath to avoid conflicts with user's Xcode.
Builds, tests, and launching the app MUST be done outside the sandbox to avoid code signing issues.

## Swift module tests

| Module | Test target |
| --- | --- |
| LDTXAudioEngine | LDTXAudioEngineTests |
| LDTXDash | LDTXDashTests |
| LDTXMediaTiming | LDTXMediaTimingTests |
| LDTXMP4 | LDTXMP4Tests |
| LDTXProgram | LDTXProgramTests |
| LDTXVideoRendering | LDTXVideoRenderingTests |
| LDTXWorkspace | LDTXWorkspaceTests |
| LDTXYouTube | LDTXYouTubeTests |
