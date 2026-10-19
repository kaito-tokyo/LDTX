<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Workspace state responsibility inventory

WorkspaceDocument is the observable owner of one editable WorkspaceV4Bundle
and the UI status for one document. UI receives the same Document. Runtime
resources belong to AppDelegate-owned WorkspaceAppletCoordinators.
Read-only content projections and explicit editing Bindings enter the Document's
synchronous edit operation; they do not perform validation, IO or runtime adoption.

| Responsibility | Owner |
| --- | --- |
| Confirmed definition, preferences, output settings and embedded models | WorkspaceDocument |
| Editable definition, preferences, output settings and model resource URLs | WorkspaceDocument (one editable value) |
| UI selection, Inspector visibility, output and Vision status | WorkspaceDocument |
| Reading and writing content snapshots | WorkspaceDocument and its Reader/Writer |
| Snapshot capture | WorkspaceDocument |
| Save validation | WorkspaceBundleWriterV4, invoked by DocumentWriter |
| Persisted runtime adoption and output-time deferral | WorkspaceAppletCoordinator |
| Applying read snapshots to editing state | WorkspaceDocument |
| Undo/Redo and standard unsaved-change tracking | WorkspaceDocument and the environment's document UndoManager |
| Runtime projection and recording/capture/audio/Vision lifetimes | WorkspaceAppletCoordinator and its runtime services |
| ProgramRuntime and Vision definition/model inputs | Last successfully persisted content, separate from in-memory confirmation |
| Live preferences | Document, projected by the runtime coordinator |
| Local state URL and transient state migration | WorkspaceAppletCoordinator |
| Device assignments, output folders, stream keys and monitor assignments | Shared AppletData |
| Program selection | Program Inspector and controller, using injected AppletData |
| Program deletion, layer membership and resource operations | Explicit controller/runtime editing operations |
| Layer transforms, audio gains, master volumes and mute edits | Direct bindings and editors with explicit numeric encoding |
| Output, screenshot and inference commands | UI actions and RuntimeCoordinator; manual inference tasks are runtime-owned |
| Runtime errors awaiting acknowledgement | WorkspaceDocument |
| Alert and screenshot popover display | Local State in the presenting UI View |
| Pane widths, preview height and canvas tab | Local State in the owning UI View |
| Dock recording badge | AppDelegate observes output changes from its registered WorkspaceAppletCoordinators |

There is no Apply/Submit registry or navigation guard for unconfirmed input.
Representable edits enter one synchronous Document operation, capturing the old
Workspace value and registering its restoration for Undo with the input View's
environment UndoManager passed directly into the operation. Document and Connection
do not cache that manager or wait for a later connection. Reverse restoration
registers Redo in the standard UndoManager invocation. Compound content changes
commit as one operation. UI selections and runtime status remain outside history.
Incomplete numeric text stays local to its control. Snapshot capture only returns
content; Writer validates it before writing, and failure leaves edits intact.

Reader applies a complete loaded value directly without registering Undo. Loaded
and canonically persisted content are distinguished from values captured for a
pending write. Runtime adoption continues to read the canonical package after
metadata changes while idle, and defers adoption during output. Its generation
and VariableStore reset behavior is unchanged.

The Coordinator is retained by the Representable, not Document. Dismantling the
representation stops UI observation and starts idempotent async
shutdown. Document can retain confirmed content independently of that UI lifetime.
