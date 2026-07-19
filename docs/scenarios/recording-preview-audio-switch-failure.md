---
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

id: SCN-RECORDING-PREVIEW-002
title: Keep Recording Preview open after an audio switch failure
status: active
priority: p0
risk: An audio switch failure is silent or destroys the usable Preview
feature: Recording Preview error handling
test_level: system
test_type: error-handling
execution: computer-use
automation: assisted
run_when:
  - Recording Preview audio selection changes
  - Recording Preview error presentation changes
  - Recording Preview window lifecycle changes
requires:
  - LDTX can launch from a Debug build
  - The audio-switch-failure fixture can be injected through the environment
tags:
  - recording-preview
  - audio-channel
  - error-modal
  - debug-fixture
---

# Keep Recording Preview Open After an Audio Switch Failure

## Objective

Verify that an audio channel switch failure is explained modally, restores the
previous selection, and leaves the Preview available.

## Preconditions

- No LDTX process is running.
- LDTX has been built with the `Debug` configuration.

## Test Data

- Environment variable: `LDTX_RECORDING_PREVIEW_FIXTURE=audio-switch-failure`
- Initial audio channel: `Main Mix`
- Failing audio channel: `Unavailable Channel`
- Expected dialog title: `Audio Channel Could Not Be Changed`

## Procedure

1. Launch the Debug LDTX executable with the fixture environment variable and
   arguments `-ApplePersistenceIgnoreState YES`.
2. In Recording Preview, press the `Unavailable Channel` audio-channel button.
3. Confirm the error dialog by pressing `OK`.

## Expected Results

- One error dialog titled `Audio Channel Could Not Be Changed` is shown.
- The selected audio channel returns to `Main Mix`.
- Pressing `OK` dismisses only the dialog.
- The Recording Preview window remains open and responsive.

## Postconditions

- Recording Preview remains open with `Main Mix` selected.

## Notes

The fixture provides UI state only; it does not require playable media. This
scenario does not define successful channel-switch behavior.
