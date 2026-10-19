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
- WorkspaceDocument owns one observable WorkspaceV4Bundle as the authoritative
  editable value, together with observable UI status. Runtime resources remain
  outside the Document.
- User edits enter a synchronous MainActor document operation, directly or
  through an explicit editing Binding. The operation captures the previous
  Workspace value and registers its restoration with the View environment's
  document UndoManager, supplied by the input View at the synchronous call site.
  Restoration uses that same manager to register Redo.
  Compound edits, including model selection and component deletion, commit once.
- No asynchronous observer reconstructs user edits or registers Undo afterward.
  Read-only field projections cannot bypass the edit operation. Reading content
  replaces the value directly without creating a user-edit Undo action.
- Workspace uses the standard document history while output is idle. Undo/Redo
  commands remain disabled during output; registration still tracks content edits.
  Other Applets retain their standard commands.

## Document content, editing state and runtime state have distinct roles

- WorkspaceDocument owns the editable Workspace value and UI state directly;
  there is no parallel mutable StateService. UI selections, runtime results and
  output status are not part of the undoable Workspace value.
- Snapshot capture returns the current value without publishing a confirmation,
  changing editable content or adopting runtime state. Writer validates and writes
  the supplied snapshot to the supplied destination. Failure retains the edits.
- Reader applies loaded content directly to the Document without registering Undo.
  The last canonical content read is distinct from a pre-write snapshot.
- WorkspaceDocumentContent retains its connection through SwiftUI State. The
  connection only routes URLs and lifecycle; input Views pass their environment
  UndoManager directly to synchronous Document edits. Document caches no manager.
  AppDelegate strongly retains one WorkspaceAppletCoordinator per transient runtime
  UUID. The Coordinator owns runtime Program pairs, previews, capture, output,
  audio and Vision. The Applet resolves it through an explicitly injected Optional
  Environment delegate and requires the dependency after View installation.
  View reconstruction preserves Coordinator identity. Close releases the application
  registration only after asynchronous cleanup; Document holds no runtime owner.
- Snapshots contain captured values and model source URLs. Model IDs are assigned
  on selection and remain unchanged during saving. Writer copies resources
  without modifying Definition and holds no callbacks into Document.
- Reader and Writer snapshots are WorkspaceV4Bundle values. Configuration owns
  document location separately. Applying a Reader snapshot replaces the whole
  editable value without Undo, preserving UI status. There is no implicit
  three-way merge, and snapshot capture never adopts or replaces editing data.
- Runtime adoption remains independent of editable content and snapshot capture.
  A canonical package read may update the recorded persisted content; pending
  edits stay in the Document until explicitly changed or a Reader applies data.

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
  snapshot until cleanup, even if Document content changes meanwhile.
  The next start captures new settings; live mix preferences remain independent.

## Vision interval execution is best effort

- Each Workspace runtime owns an ephemeral `[LDTXVariableKey: String]` dictionary.
  Its inventory and item defaults are projected from the saved Definition. Keys
  belong to the Workspace model and contain opaque `id` and `sel` strings.
  OCR and Scene Detector producers interpret them as Vision IDs and item names.
  Updates validate all keys before mutation; reset preserves the inventory.
- Native rich text persistence and attachment data belong to the macOS-only
  `LDTXRichText` target. `LDTXVariableMacro` owns the editor and chip presentation.
  Corelibs holds RTFD as opaque bytes and does not claim to validate its contents.
- Successful persisted Workspace adoption recreates the entire Store, including
  when a save leaves the Definition unchanged. Editing or a failed save does not
  reset it. In-flight results from an earlier Store generation cannot update the
  new Store. Store access and result publication are serialized on MainActor.

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

## Overlay production is independent of Program frame rendering

- Dynamic Text rasterization rejects more than 8,388,608 pixels before allocating
  its CPU buffers or textures. At 10 bytes per pixel across staging buffers and
  textures, this bounds those allocations to 80 MiB per render while permitting 4K UHD.

- Workspace owns Clock and Dynamic Text texture producers separately from
  ProgramRuntime, preview consumers, output consumers, and on-demand frame rendering.
  Producers can prepare and update textures without requesting a Program frame.
- Dynamic Text observes the Workspace's ephemeral variable state. Changes schedule
  texture generation independently; they do not poll at frame rate or reconfigure
  ProgramRuntime. Clock updates use their own timer.
- ProgramRuntime only reads snapshots of completed textures and composites them.
  Its frame loop must not initialize, synchronize, or start texture generators.
  Generation and publication never wait for the compositor, and composition never
  waits for a new overlay. The last completed texture remains usable during refresh.
- Published textures are immutable. Generation identity rejects late publication
  after removal or shutdown. Each canvas owns its producer and placement projection;
  failed refreshes retain the last successful texture. Definition changes still
  reach producers only after successful persistence.

## Dynamic Text uses native rich text persistence

- `rtfd_document` is the sole authoritative content. It contains flattened RTFD
  produced by NSAttributedString. An empty document has valid RTFD data; absent
  or empty bytes are invalid. Legacy XML/text fields are reserved and unsupported.
- The RTFD document owns fonts, sizes, colors and paragraph formatting. Standard
  native formatting commands are used. Program preserves font sizes and wraps
  and clips to the configured extent; it never automatically shrinks text.
- Variables are NSTextAttachment files with extension `.ldtxvar` and UTF-8 JSON:
  `{ "version": 1, "id": "...", "sel": "...", "body": "..." }`.
  All fields are required. Identifiers, selectors and bodies are opaque strings;
  no script evaluation is performed. Unsupported versions, malformed JSON and
  non-variable attachments are rejected. Filenames do not identify variables.
- Persistent data lives in the attachment FileWrapper, independently of its
  regenerated chip cell. Custom character attributes and chip images are not
  the source of variable identity. Reading or refreshing labels never rewrites
  persisted bytes. Semantic equality ignores generated filenames and images.
- The same codec validates macOS Workspace reads, writes, adoption and paste.
  Failed reads do not become empty documents; failed exports retain the editor
  draft and report an error without overwriting the authoritative bytes.
- Clipboard RTFD preserves variables and formatting. RTF and plain-text exports
  replace variables with readable reference text. Literal pasting never parses
  reference syntax. Unresolved variables remain editable and expand to empty.
- Variable expansion replaces attachments with literal values using each run's
  formatting. The producer generates textures outside frame rendering; the
  compositor only reads retained textures. The raster pixel budget still applies.
- Editor synchronization preserves marked text and does not replace an unchanged
  edit echo. Text and attribute changes share Workspace document Undo/Redo; native
  text undo is disabled and no private history or undo shortcut interception exists.

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

## Editing commits synchronously to WorkspaceDocument

- SwiftUI edits commit the Document's authoritative Workspace value. There
  is no separate Submit or Apply operation and no window-wide draft registry.
- Input controls may retain incomplete or unrepresentable numeric text locally;
  they must write representable values without requiring Return. Navigation does
  not require a separate confirmation operation.
- Semantic validation, including Vision ROI bounds and rational denominators,
  occurs when saving. Failed validation preserves the edits in the Document and
  leaves the persisted Definition and runtime unchanged.
- Changing screens or starting output does not implicitly save the Definition.

## Video visibility terminology

Use Hidden and Visibility for video layers and components, including model APIs,
persistence fields, rendering, and tests. Reserve Mute and Muted for audio.

Hidden video layers are excluded from Program composition, including VFX Sources.
Do not replace hidden layers with dummy images. Visibility does not stop capture
or change the configured PTS master.
