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

## PERSISTENCE: Separate definition, preferences, and output settings

- `definition` is the authoritative inventory of Workspace resources and Programs.
  No definition field may change while recording or streaming is active.
- `preferences` contain presentation and mix state, including each Program and
  canvas's video layer order, transforms, visibility, mute state, and gain.
- Video layer IDs are ordered from back to front. During output, reordering is
  allowed, but layer membership and occurrence counts must remain unchanged.
- Other preferences may change during output when the pipeline supports them.
- `outputSettings` is a separate persisted Workspace document for recording and
  streaming configuration. It may change between sessions, but remains fixed
  while output is active.
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

## Dynamic selection starts unselected

- Selection controls populated from dynamic resources must start with no selection.
- Restored assignments and asynchronously resolved references are displayed separately from editing controls.
- Editing sheets must not preselect a saved value or the first available candidate. Only an explicit user selection may be applied.
- Candidate removal clears the editing selection without replacing it or changing the saved assignment.
- The Program list is a static set of candidates defined by the authoritative
  Workspace definition. Its selection control may display the currently
  resolved Program, including a restored selection. This does not change the
  unselected-draft policy for dynamic resource editing sheets.

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

## Invalid edits prevent leaving their screen

- A screen containing invalid edited values cannot be left. Attempted navigation
  must report the validation error and preserve the current screen and draft.
- Validate at multiple layers. Ordinary edits that were allowed to leave their
  screen must not become latent validation failures discovered only on save.
- OCR ROI text remains a draft until the whole rectangle is valid. Inspector
  selection, Program changes, output start, save, and document close must respect
  pending invalid edits.
- Content Editors register weakly captured draft validators with the Workspace
  store. Master-volume and layer-transform drafts participate in the same
  navigation, output-start, save, and close validation as OCR ROI drafts.
  Validation checks the current text without committing or discarding it.

## Video visibility terminology

Use Hidden and Visibility for video layers and components, including model APIs,
persistence fields, rendering, and tests. Reserve Mute and Muted for audio.

Hidden video layers are excluded from Program composition, including VFX Sources.
Do not replace hidden layers with dummy images. Visibility does not stop capture
or change the configured PTS master.
