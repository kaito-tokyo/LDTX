---
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

id: SCN-RECORDING-PREVIEW-001
title: Close Recording Preview after an initial load failure
status: active
priority: p0
risk: A failed recording remains as an unusable Preview window
feature: Recording Preview error handling
test_level: system
test_type: error-handling
execution: computer-use
automation: assisted
run_when:
  - Recording Preview loading changes
  - Recording Preview error presentation changes
  - Recording Preview window lifecycle changes
requires:
  - LDTX can launch from a Debug build
  - The initial-load-failure fixture can be injected through the environment
tags:
  - recording-preview
  - error-modal
  - window-lifecycle
  - debug-fixture
---

# Close Recording Preview After an Initial Load Failure

## Objective

Verify that a recording which cannot be opened produces one user-facing error
and does not leave an unusable Preview window behind.

## Preconditions

- No LDTX process is running.
- LDTX has been built with the `Debug` configuration.

## Test Data

- Environment variable: `LDTX_RECORDING_PREVIEW_FIXTURE=initial-load-failure`
- Expected dialog title: `Recording Could Not Be Opened`

## Procedure

1. Launch the Debug LDTX executable with the fixture environment variable and
   arguments `-ApplePersistenceIgnoreState YES`.
2. Wait for the Recording Preview window and error dialog to appear.
3. Press `OK` in the error dialog.

## Expected Results

- One error dialog titled `Recording Could Not Be Opened` is shown.
- The dialog explains that the recording could not be opened.
- Pressing `OK` closes the Recording Preview window.
- The main LDTX window remains open and responsive.
- No empty or loading Recording Preview window remains.

## Postconditions

- LDTX remains running with only its normal windows open.

## Notes

This scenario intentionally verifies only the stable error landing protocol.
It does not validate successful recording playback.
