---
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

id: SCN-RECORDING-PREVIEW-003
title: Close Recording Preview after an internal state failure
status: active
priority: p0
risk: An invalid internal state leaves a misleading or unsafe Preview window
feature: Recording Preview error handling
test_level: system
test_type: error-handling
execution: computer-use
automation: assisted
run_when:
  - Recording Preview state management changes
  - Recording Preview logging changes
  - Recording Preview window lifecycle changes
requires:
  - LDTX can launch from a Debug build
  - The internal-state-failure fixture can be injected through the environment
  - Unified logging can be observed outside the sandbox
tags:
  - recording-preview
  - oslog
  - window-lifecycle
  - debug-fixture
---

# Close Recording Preview After an Internal State Failure

## Objective

Verify that an unexpected internal state is recorded for diagnosis and closes
the Preview without presenting an unreliable recovery UI.

## Preconditions

- No LDTX process is running.
- LDTX has been built with the `Debug` configuration.
- A unified log stream is observing subsystem `tokyo.kaito.ldtx` and category
  `RecordingPreview`.

## Test Data

- Environment variable: `LDTX_RECORDING_PREVIEW_FIXTURE=internal-state-failure`
- Expected log text: `The internal-state-failure scenario fixture was activated.`

## Procedure

1. Start the unified log stream.
2. Launch the Debug LDTX executable with the fixture environment variable and
   arguments `-ApplePersistenceIgnoreState YES`.
3. Observe the Recording Preview window lifecycle and captured log output.

## Expected Results

- The Recording Preview window closes without user interaction.
- No error dialog is shown for the internal state failure.
- Unified logging contains the expected message under subsystem
  `tokyo.kaito.ldtx` and category `RecordingPreview`.
- The main LDTX window remains open and responsive.

## Postconditions

- LDTX remains running with only its normal windows open.
- The diagnostic log remains available in unified logging.

## Notes

Run `/usr/bin/log stream --level error --predicate 'subsystem ==
"tokyo.kaito.ldtx" AND category == "RecordingPreview"'` outside the sandbox
to observe the diagnostic message.
