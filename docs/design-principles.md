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
  model rather than maintaining an independent V3-style representation.

## Preferences are permissive input

- Preferences may contain values that are not meaningful for every component
  type.
- The preference model accepts the complete set of preference fields.
- The runtime is responsible for applying supported values and safely ignoring
  unsupported values.

## PERSISTENCE: Separate definition from preferences

- `definition` is the authoritative Workspace structure, including resources,
  Programs, layers, physical assignments, and output configuration.
- `definition` must not be changed while recording or streaming is active.
- `preferences` contain editable presentation and mix state, such as
  transforms, mute state, gain, and selections.
- `preferences` may be changed while output is active when the running output
  pipeline supports the change.
- The UI must prevent changes to `definition` during active output while
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
