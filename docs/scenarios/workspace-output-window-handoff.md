---
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

id: SCN-WORKSPACE-MODE-001
title: Lock and unlock a Workspace with the Output mode toggle
status: active
priority: p0
risk: Output can use stale Workspace state or allow editing while a session is active
feature: Workspace mode toggle
test_level: system
test_type: regression
execution: computer-use
automation: assisted
run_when:
  - Workspace mode or Output session lifecycle changes
  - Output start or stop behavior changes
  - Workspace save or lock behavior changes
requires:
  - LDTX can launch locally
  - A writable temporary directory is available
  - Screen-recording and microphone permissions are granted when the selected Program requires them
tags:
  - workspace
  - output-mode
  - edit-lock
  - persistence
  - lock-lifecycle
---

# Lock and Unlock a Workspace with the Output Mode Toggle

## Objective

Verify that one Workspace Window switches between Edit and Output modes. Output
mode must save and lock Workspace editing, retain the live session in the same
Window, and allow Edit mode again only after Output has fully stopped.

## Preconditions

- No LDTX Output session is active.
- Start from a new Workspace or a Workspace with unsaved changes.
- Configure a locally recordable Output destination and an active Program that
  can start without an external broadcast.

## Test Data

- Workspace filename: `Output Window Handoff.ldtxworkspace`
- Save location: a newly created temporary directory
- Expected mode control accessibility identifier: `workspaceOutputModeToggle`
- Expected Program control accessibility identifier: `activeProgramSegmentedControl`
- Expected stop control accessibility identifier: `outputStopButton`

## Procedure

1. Launch LDTX and open the Workspace Editor.
2. Make one visible Workspace edit, such as changing the Workspace name.
3. Turn on `workspaceOutputModeToggle`.
4. When Save As is shown, save as `Output Window Handoff.ldtxworkspace` in the
   temporary directory.
5. Confirm the same Window remains open and now contains `Output Session`,
   Audio Mix, Video Components, and a Preview pane.
6. Stop Output if needed, return to Edit mode, and select an Input Device or
   Video Component in the Sidebar.
7. Start Output with `outputStartButton` and confirm the Sidebar, Content Pane,
   and Detail Pane all switch to Output.
8. While Output is active, try to turn off Output mode and confirm the Window remains in
   Output mode.
9. Press `outputStopButton`, then turn off `workspaceOutputModeToggle`.
10. Confirm the same Window displays the editable Workspace again.

## Expected Results

- Starting Output prompts for a save when the Workspace has no package URL.
- Switching to Output saves the Workspace and changes the same Window's UI.
- Toggle and toolbar starts clear the previous resource selection before
  showing Output controls.
- Output mode owns Program selection, Audio Mix, Video Component navigation,
  and Preview throughout the session.
- Edit mode cannot be entered while Output is active or paused.
- Stopping Output leaves the Window open and makes Edit mode available again.
- Returning to Edit restores Input Device and other Workspace-global editing.

## Postconditions

- The Workspace Window remains open in Edit or stopped Output mode.
- The saved Workspace package can be reopened normally.

## Notes

Run this scenario with a local recording destination to avoid creating or
modifying a YouTube broadcast.
