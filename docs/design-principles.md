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
- The Representable Coordinator registers undo actions for content changes to participate
  in SwiftUI's unsaved-change tracking. StateService must not hide document-change
  callbacks or persistence notifications in its setters.
  Workspace Undo/Redo menu commands and shortcuts are temporarily disabled;
  registration remains enabled for change tracking. Other Applets keep their
  standard Undo/Redo commands.

## Document content, editing state and runtime state have distinct roles

- WorkspaceDocument owns the confirmed in-memory Workspace content.
  StateService values are confirmed in Document before their snapshot is validated and written
  to disk. The direction is StateService → Document → Disk; write failure does
  not roll back the confirmed content, which remains unsaved.
- WorkspaceDocument owns WorkspaceStateService and its temporary editing values
  and UI state. Document captures those values directly when saving; Writer
  validates them before writing. Saving does not require a represented UI or an editing connection.
- The Representable receives Document and owns the WindowController through its
  Coordinator. UI receives Document's StateService through Bindable. Runtime
  ProgramRuntime pairs and preview MTKViews are constructed and retained by App
  State, keyed by the Document's transient UUID, and injected through initializers.
  WindowController operates those resources and releases their App registration
  only after asynchronous shutdown. Document does not own the controller.
- Snapshot preparation confirms only captured values; newer edits stay in
  StateService. Model IDs are assigned on selection and remain unchanged during
  saving. Snapshots contain model source URLs; Writer copies those resources
  without modifying the Definition and holds no shared
  receipts or callbacks into Document. Runtime persistence tracking is separate
  from in-memory document confirmation.
- Reader and Writer snapshots are WorkspaceV4Bundle values. Configuration owns
  the document location separately. Model resource URLs are keyed by their model
  IDs within the Bundle and Document's StateService.
- Applying a Reader snapshot only replaces Document's content. UI and runtime
  consumers observe Document changes and independently adopt or defer
  updates. A consumer's output state must not prevent Document from updating.
- The connection updates StateService fields directly. Full overwrite
  replaces Definition, Preferences, OutputSettings, envelope IDs and model URLs.
  URL-only synchronization updates URLs for model IDs already present in
  StateService; it does not add or remove models or change Vision references or
  other editing values. There is no implicit three-way or field-level merge.
- Reader content is adopted with full overwrite by the Representable Coordinator.
  Snapshot capture also adopts an unread Reader generation into StateService,
  so headless saving cannot replace read content with initial editing values.
  Adoption is shared and runs once per Reader generation.
  URL-only synchronization is an explicit operation, not a side effect of saving.

## Definition changes reach the runtime only after persistence

- New Workspaces open and accept edits before their first save. Their external
  IDs are allocated at creation, independently of a package location. Output
  requires a saved document URL and a successfully persisted runtime snapshot;
  creating a snapshot or completing a staging write alone does not enable it.

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
- RecordingSession captures OutputSettings before entering the starting state.
  Service construction, subscriptions, and session reconfiguration use that
  snapshot until cleanup, even if Document or StateService changes meanwhile.
  The next start captures new settings; live mix preferences remain independent.

## Vision interval execution is best effort

- Absent ROI fields use input-pixel defaults: X/Y numerators are zero,
  Width/Height numerators are the input width/height, and denominators are
  the corresponding input dimension. UI placeholders, persistence validation,
  and inference share this interpretation. Missing fields remain absent on disk;
  explicit zero denominators remain invalid. Defaults are resolved without changing
  the editable or saved protobuf values.

- OCR and Scene Detector interval triggers use the successfully persisted
  Definition while the Workspace window is open, including while output is idle.
- Automatic requests share one execution lane per Workspace. Each 30-second
  frame is planned in 1 ms units with a fixed 3 ms budget for either request
  type. This is an initial placement budget, not a measured execution guarantee.
- Initial phases are randomized. Collisions move forward within the frame;
  requests that cannot fit are randomly thinned. Busy or overdue occurrences
  are skipped without queuing catch-up work or cancelling an active request.
- Models are prepared separately and reused. Output start waits for compilation
  and loading of referenced models. During output, manual and automatic inference
  use only loaded services and skip unavailable models; neither loads nor compilation
  are started. Corrupt caches fail without recompilation.
  Preparation failures retry after configuration or output-state changes.
- Manual inference remains independent and may overlap automatic work. Stops
  drain active automatic requests and model preparation; stale generations
  cannot publish results. Scheduling statistics are logged per frame.
- Window shutdown waits for active manual inference before stopping its runtime.
  Closed windows reject new requests and discard results without cancelling the work.
- Inspecting a selected model's information only queries an existing compiled
  asset; it does not compile or load an inference model. Information becomes
  available after normal model preparation.
  Preparation completion notifies the editing UI to retry its metadata query,
  even when the model URL and output state remain unchanged.

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
  Runtime preference projection retains the layer membership and occurrence
  counts captured when output starts. Structural reloads stay pending until
  output is idle; valid ordering, mix, transforms, and visibility remain live.
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
  the user.
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
