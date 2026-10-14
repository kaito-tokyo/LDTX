<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# UI Rules

This document is the source of truth for UI-specific behavior in LDTX.
Implementation, tests, and reviews should follow these rules alongside the
[design principles](design-principles.md).

## Dynamic selection in the Workspace main window starts unselected

- In the Workspace main window, selection controls populated from dynamic
  resources must start with no selection. This area may appear immediately at
  application startup, before resource discovery has resolved its candidates.
- In that area, restored assignments and asynchronously resolved references are
  displayed separately from editing controls. Candidate removal clears only the
  editing selection, without replacing it or changing the saved assignment.
- This initial-selection restriction applies only to the Workspace main window,
  not to editing sheets explicitly opened by the user. Device selection was moved
  into a sheet to keep it outside the area that may appear at startup. Such a
  sheet may preselect the saved assignment when its candidate is available;
  opening the sheet or discovering candidates must not itself change the saved
  assignment.
- Candidates defined by the Workspace Definition are outside this dynamic-device
  selection rule. This includes Programs, Video Components used as Vision inputs,
  and VFX Sources used as the PTS master. Their controls may bind directly to the
  defined assignment and display a restored selection; no initially unselected
  editing draft or separate restored-assignment display is required. A VFX Source
  defined in the Workspace remains a Definition-derived candidate regardless of
  whether its physical device is currently connected. Selection of the physical
  device itself remains subject to the dynamic-resource rule above.

