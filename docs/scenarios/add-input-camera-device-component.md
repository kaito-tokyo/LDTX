---
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

id: SCN-INPUT-001
title: Add an Input Camera Device component
status: active
priority: p1
risk: Program editor does not expose input device binding controls
feature: Program video components
test_level: system
test_type: regression
execution: computer-use
automation: assisted
run_when:
  - Program component editor UI changes
  - Input device picker UI changes
  - Workspace input device model changes
requires:
  - LDTX can launch locally
  - UI testing state isolation is available when possible
  - A default Program exists
tags:
  - program-editor
  - video-components
  - input-devices
---

# Add an Input Camera Device Component

## Objective

Verify that adding an `Input Camera Device` video component exposes the
workspace input device picker in the Program editor.

## Preconditions

- LDTX launches successfully.
- The current workspace contains the default Program.
- The current Program has no input camera component.

## Test Data

- Component type: `Input Camera Device`
- Empty input device label: `No input device`

## Procedure

1. Launch LDTX.
2. Select `Edit Current Program` in the sidebar.
3. Confirm the detail pane shows the Program editor.
4. Confirm no input device picker is shown for the default Program.
5. Press the add button in `Video Components`.
6. Open the component type picker for the newly added component.
7. Choose `Input Camera Device`.

## Expected Results

- A new video component is visible in `Video Components`.
- The component type reads `Input Camera Device`.
- The component exposes an `Input Device` picker.
- If the workspace has no configured input devices, the picker reads `No input device`.

## Postconditions

- The current Program contains one input camera device component.

## Notes

If the workspace already contains configured input devices, the picker may show
an available logical input device instead of `No input device`.

