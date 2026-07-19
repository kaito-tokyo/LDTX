---
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

id: SCN-PROGRAM-002
title: Reject duplicate generated Program names
status: active
priority: p1
risk: Program creation silently overwrites or selects the wrong Program
feature: Program management
test_level: system
test_type: error-handling
execution: computer-use
automation: assisted
run_when:
  - Program creation logic changes
  - Program naming logic changes
  - Program error presentation changes
requires:
  - LDTX can launch locally
  - A workspace can be prepared with a duplicate next generated Program name
tags:
  - program-creation
  - program-naming
  - error-modal
---

# Reject Duplicate Generated Program Names

## Objective

Verify that Program creation stops and presents an error when the generated
Program name already exists.

## Preconditions

- LDTX launches successfully.
- The workspace already contains a Program named with the next generated name.
  For example, when there is one Program, `New Program 2` already exists.

## Test Data

- Duplicate generated name example: `New Program 2`

## Procedure

1. Launch LDTX.
2. Press the toolbar add Program button.
3. Confirm the generated name is shown in the `Add Program` dialog.
4. Press `Add` without changing the name.

## Expected Results

- No new Program is created.
- The current active Program does not change.
- An error dialog explains that the generated Program name already exists.

## Postconditions

- The workspace Program list is unchanged.
- The user remains in the same editing context.

## Notes

Do not accept fallback naming in this scenario. A duplicate generated name is
expected to stop the action.
