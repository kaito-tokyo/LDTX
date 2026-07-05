---
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

id: SCN-PROGRAM-001
title: Add a Program from the toolbar
status: active
priority: p0
risk: Program creation changes active editing context unexpectedly
feature: Program management
test_level: system
test_type: smoke
execution: computer-use
automation: assisted
run_when:
  - Toolbar layout changes
  - Program selector behavior changes
  - Program creation or naming logic changes
requires:
  - LDTX can launch locally
  - UI testing state isolation is available when possible
  - The workspace starts with exactly one Program
tags:
  - toolbar
  - program-selector
  - program-creation
---

# Add a Program from the Toolbar

## Objective

Verify that the toolbar add Program action creates the next numbered Program
and keeps the user in the current Program editing workflow.

## Preconditions

- LDTX launches successfully.
- The current workspace contains exactly one Program.
- The active Program selector reads `New Program 1`.

## Test Data

- Initial Program name: `New Program 1`
- Expected created Program name: `New Program 2`

## Procedure

1. Launch LDTX.
2. Confirm the toolbar shows `Stop`, `Start`, and the active Program selector on the left.
3. Confirm the active Program selector reads `New Program 1`.
4. Press the toolbar add Program button.

## Expected Results

- A new Program is created.
- The active Program selector changes to `New Program 2`.
- `Edit Current Program` remains selected in the sidebar.
- The detail pane remains on the current Program editor.
- The new Program can accept a new component from `Video Components`.

## Postconditions

- The workspace contains `New Program 1` and `New Program 2`.
- `New Program 2` is the active Program.

## Notes

This is a `p0` smoke scenario because Program creation is a primary editing
workflow and a frequent regression point for toolbar and sidebar changes.

