<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Design Principles

This document is the source of truth for cross-cutting design decisions in
LDTX. Implementation, tests, and reviews should follow these principles.

Design Principles (DP) define the project-wide invariants and decision rules
that must remain consistent across modules. They are normative guidance for
architecture, persistence, runtime behavior, UI behavior, and tests. DP should
describe *what must be true* and *how trade-offs are decided*; detailed API
contracts, individual control behavior, and implementation procedures belong in
the relevant design or feature documentation instead.

## Version 4 is the authoritative workspace model

- Version 4 Workspace protobuf documents are the authoritative representation
  of a V4 Workspace.
- Runtime state, editor state, and persistence code must project from that
  model rather than maintaining an independent parallel representation.

## Preferences are permissive input

- Preferences may contain values that are not meaningful for every component
  type.
- The preference model accepts the complete set of preference fields.
- The runtime is responsible for applying supported values and safely ignoring
  unsupported values.

## PERSISTENCE: Separate definition from preferences

- `definition` is the authoritative Workspace structure, including resources,
  Programs, layers, physical assignments, and output configuration.
- While recording or streaming is active, `definition` changes are limited to
  reordering existing video layers within each Program and canvas. Layer IDs and
  their occurrence counts must remain unchanged; all other definition fields
  remain fixed.
- `preferences` contain editable presentation and mix state, such as
  transforms, mute state, gain, and selections.
- `preferences` may be changed while output is active when the running output
  pipeline supports the change.
- The UI must prevent other changes to `definition` during active output while
  continuing to allow supported `preferences` changes.

## Device availability must not make output start unintuitive

- A disconnected or unassigned input device must not, by itself, prevent
  recording or streaming from starting.
- The affected input should be represented as unavailable.
- Its status should be visible to the user.
- Capture synchronization should retry when the device becomes available.
- Only a configuration error that makes the selected output fundamentally
  invalid may prevent startup.

## Preserve observable failures

- Failures during startup, output, and finalization must remain observable to
  the user and diagnostics.
- Cleanup must not replace an actionable failure with a generic idle or
  successful state.

## Keep expensive media work off the main actor

- Image conversion, encoding, and filesystem work associated with media output
  must not block the main actor.
- Such work should use a serialized background executor when ordering is
  significant.

## Dynamic selection starts unselected

- Selection controls populated from dynamic resources must start with no selection.
- Restored assignments and asynchronously resolved references are displayed separately from editing controls.
- Editing sheets must not preselect a saved value or the first available candidate. Only an explicit user selection may be applied.
- Candidate removal clears the editing selection without replacing it or changing the saved assignment.
- The Program list is a static set of candidates defined by the authoritative
  Workspace definition. Its selection control may display the currently
  resolved Program, including a restored selection. This does not change the
  unselected-draft policy for dynamic resource editing sheets.

## Rational values and optional transforms

- Construct or update Rational32 values through `set(num:den:)` or
  `set(decimal:)`; application code must not assign numerator or denominator
  directly. Generated protobuf code is exempt.
- `set(num:den:)` preserves the supplied representation without validation or
  reduction. `set(decimal:)` encodes a representable Decimal exactly with a
  power-of-ten denominator; an encoding overflow leaves the prior value intact.
- Read through `float`, `double`, or `decimal`. All three interpret `0/0` as
  zero without mutating the stored representation. Other zero denominators
  follow the numeric type's division rules.
- BasicTransform's optional accessors preserve protobuf presence. Setting an
  accessor to nil clears the field. Runtime defaults apply only to absent
  fields: translation and insets default to zero, while scale defaults to one.
- Decimal editing uses `decimal` and `set(decimal:)`. Float and Double have no
  generic setters; each caller owns its quantization and encoding policy.
