<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Design Principles

This document is the source of truth for cross-cutting design decisions in
LDTX. Implementation, tests, and reviews should follow these principles.
UI-specific rules are maintained in [UI Rules](ui-rules.md).

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
- WorkspaceStateService exposes its editable protobuf values as ordinary stored
  properties. Assignments must remain transparent: setters must not silently
  reject, reinterpret, or replace an assigned value. Editing restrictions and
  validation belong to explicit editing operations and their UI owners.
- The editing connection registers undo actions for content changes to participate
  in SwiftUI's unsaved-change tracking. StateService must not hide document-change
  callbacks or persistence notifications in its setters.

## Confirmed document content and editing state have separate owners

- WorkspaceDocument owns the confirmed Workspace content. It changes after a
  successful read or after a successful write is verified at the formal document
  URL. A write to a staging location alone does not confirm the content.
- WorkspaceWindowController owns WorkspaceStateService, its temporary editing
  values and UI state, and the runtime resources. Document does not own the
  controller or a continuously synchronized copy of its edits.
- The Representable's Coordinator owns the controller and the connection to
  Document. Document holds that connection weakly. Snapshot capture reads the
  editor only when saving; saving without a connected editor fails explicitly.
- A failed save preserves the edits and confirmed content. Successful saves
  confirm only their captured values; newer edits stay in StateService. Import
  results reconcile model revisions without replacing newer editing selections.

## Definition changes reach the runtime only after persistence

- This rule applies across the entire Workspace runtime, including
  ProgramRuntime and Vision inference. Changes to the Store's
  `workspaceDefinition` must not reach the runtime until they have been
  successfully written to disk.
- The runtime uses the last successfully persisted Definition. A failed save
  leaves that runtime Definition unchanged. If editing continues during a save,
  only the successfully saved Definition is applied; subsequent edits remain
  pending for a later save.
- The Store's `workspaceDefinition` retains the current edits. Editing UI and
  prospective range previews may use those values before saving, but runtime
  execution must use the persisted Definition. In particular, Vision ROI edits
  are validated on save and are not passed to inference before persistence.
- `workspacePreferences` may reach the runtime before they are written to disk,
  subject to the runtime's supported operations and output restrictions.

## Preferences are permissive input

- Preferences may contain values that are not meaningful for every component
  type.
- The preference model accepts the complete set of preference fields.
- The runtime is responsible for applying supported values and safely ignoring
  unsupported values.

## PERSISTENCE: Separate definition, preferences, and output settings

- `definition` is the authoritative inventory of Workspace resources and Programs.
  Editing operations and UI controls must prevent definition edits while
  recording or streaming is active; the Store does not enforce this by rejecting
  property assignments.
- `preferences` contain presentation and mix state, including each Program and
  canvas's video layer order, transforms, visibility, mute state, and gain.
- Video layer IDs are ordered from back to front. During output, reordering is
  allowed, but layer membership and occurrence counts must remain unchanged.
- Other preferences may change during output when the pipeline supports them.
- `outputSettings` is a separate persisted Workspace document for recording and
  streaming configuration. Editing controls may change it between sessions;
  each active output session uses the configuration captured at startup.
- Device assignments, recording folder paths, and stream-key assignments belong
  to AppletData rather than the Workspace documents. Workspace-specific output
  assignments are keyed by the definition envelope's external ID.

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

## Protobuf defaults and Rational values

- Read ordinary protobuf fields through their generated getters, which expose
  the schema's fixed defaults. Do not turn absent fields into contextual defaults
  or hide presence checks inside convenience accessors. Oneof absence must be
  handled explicitly; validation may inspect field presence.
- Construct or update Rational values through `set(num:den:)` or
  `set(decimal:)`; application code must not assign numerator or denominator
  directly. Generated protobuf code is exempt.
- Rational32 defaults to zero; Rational32DefaultOne defaults to one. Use the
  latter only for fields whose baseline is the multiplicative identity.
- `set(num:den:)` preserves the supplied representation without validation or
  reduction. `set(decimal:)` encodes a representable Decimal exactly with a
  power-of-ten denominator; an encoding overflow leaves the prior value intact.
- Read through `float`, `double`, or `decimal`. Zero denominators follow the
  numeric type's division rules, including NaN for `0/0`; do not reinterpret
  that representation as zero.
- Transform translation defaults to zero and scale defaults to one through
  their protobuf types. Scale has no sign restriction.
- OCR minimum text height uses its protobuf default of zero. Absence does not
  select Vision's framework default.
- Decimal editing uses `decimal` and `set(decimal:)`. Float and Double have no
  generic setters; each caller owns its quantization and encoding policy.

- Continuous sliders use an explicit encoding precision instead of parsing the
  full decimal expansion of a Double. Gradient sliders use a denominator of
  1,000,000. Unrepresentable input preserves the last value rather than
  replacing it with an empty Rational.
- Every decibel-valued Rational32 uses a fixed denominator of 10, including
  channel gains, master volumes, and monitor volumes. The numerator represents
  tenths of a decibel. Quantize committed values to 0.1 dB and do not reduce the
  fraction: zero is stored as `0/10`, and -11.9 dB as `-119/10`.
- Reject non-finite or unrepresentable decibel edits before changing the model,
  preserving the previous value and the invalid editing draft.

## Editing writes directly to WorkspaceStateService

- Representable edits update the Store's authoritative documents directly. There
  is no separate Submit or Apply operation and no window-wide draft registry.
- Input controls may retain incomplete or unrepresentable numeric text locally;
  they must write representable values without requiring Return. Navigation does
  not require a separate confirmation operation.
- Semantic validation, including Vision ROI bounds and rational denominators,
  occurs when saving. Failed validation preserves the edits in the Store and
  leaves the persisted Definition and runtime unchanged.
- Changing screens or starting output does not implicitly save the Definition.

## Video visibility terminology

Use Hidden and Visibility for video layers and components, including model APIs,
persistence fields, rendering, and tests. Reserve Mute and Muted for audio.

Hidden video layers are excluded from Program composition, including VFX Sources.
Do not replace hidden layers with dummy images. Visibility does not stop capture
or change the configured PTS master.
