---
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

id: SCN-WORKSPACE-CONTENT-001
title: Route the Content Pane from the Workspace Sidebar selection
status: active
priority: p1
risk: A stale preview can show the wrong resource or retain a capture subscription
feature: Workspace contextual Content Pane
test_level: system
test_type: regression
execution: computer-use
automation: assisted
run_when:
  - Workspace Sidebar selection behavior changes
  - Input Device or Video Component preview behavior changes
requires:
  - LDTXTiny can launch locally
  - A Workspace contains one video input, one audio input, and one Video Component
tags:
  - workspace
  - sidebar
  - preview
  - video-component
  - capture-lifecycle
---

# Route the Content Pane from the Workspace Sidebar Selection

## Objective

Verify that the Content Pane follows the selected Workspace resource while the
Detail Pane remains responsible only for that resource's settings.

## Test Data

- Video input: `1-ScreenVideo`
- Audio input: `2-ScreenAudio`
- Video Component: `3-MainScreen`
- Program content accessibility identifier: `workspaceProgramContent`
- Input preview accessibility identifier: `workspaceInputDevicePreview`
- Component preview accessibility identifier: `workspaceVideoComponentPreview`
- Empty-state accessibility identifier: `workspaceContentEmptyState`

## Procedure

1. Launch LDTXTiny and open a Workspace containing the Test Data resources.
2. Select Output and confirm the existing Program Preview, Audio Mix, and
   Program Video Components UI is shown in `workspaceProgramContent`.
3. Select `1-ScreenVideo` and confirm `workspaceInputDevicePreview` shows the
   unprocessed device image.
4. Select `2-ScreenAudio` and confirm `workspaceInputDevicePreview` shows the
   input spectrogram.
5. Select `3-MainScreen` and confirm `workspaceVideoComponentPreview` shows
   only that component after Crop processing and before Destination placement.
6. Confirm each Crop field is labeled `%`, then change each edge in the Detail Pane and confirm the component preview
   updates while retaining the original Program Canvas framing.
7. Enable Background Removal. In a target that supports it, confirm the effect
   appears. In LDTXTiny, confirm Crop remains visible and an unavailable notice
   is shown.
8. Alternate between Output, both Input Devices, and the Video Component at
   least five times.
9. Delete the currently selected resource and confirm the Content Pane changes
   safely to `workspaceContentEmptyState` or the Sidebar's replacement selection.

## Expected Results

- Each Sidebar selection routes to exactly one matching Content Pane.
- Raw Video Input preview does not inherit Crop, Background Removal, or
  Destination from any Video Component.
- Video Component preview contains no other Program components and ignores its
  Program Destination while preserving the Program Canvas framing.
- The Detail Pane edits only the selected resource and updates its preview.
- Repeated selection changes do not leave stale images, duplicate capture
  subscriptions, frozen previews, or crashes.

## Postconditions

- No Output session or Program Active Snapshot is created or changed by these
  confirmation-only previews.
