<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Workspace state responsibility inventory

WorkspaceStateService holds editable protobuf values and observable UI/runtime
facts for one Workspace document. WorkspaceDocument owns it alongside its
workspaceSnapshot and persistence. UI receives that same instance through
Bindable; WindowController retains a reference while managing runtime resources.
Assignments to StateService's stored properties remain transparent; direct
Bindable access does not hide validation, persistence, or runtime synchronization.

| Responsibility | Owner |
| --- | --- |
| Confirmed definition, preferences, output settings and embedded models | WorkspaceDocument |
| Editable definition, preferences, output settings and model resource URLs | WorkspaceStateService, owned by Document |
| UI selection, Inspector visibility, output and Vision status | WorkspaceStateService |
| Reading and writing content snapshots | WorkspaceDocument and its Reader/Writer |
| Snapshot capture | WorkspaceDocument |
| Save validation | WorkspaceBundleWriterV4, invoked by DocumentWriter |
| Persisted runtime adoption and output-time deferral | WorkspaceWindowController |
| Applying read snapshots to editing state | SwiftUI scene connection |
| Undo/Redo and standard unsaved-change tracking | SwiftUI scene connection and the window's UndoManager |
| Runtime projection and recording/capture/audio/Vision lifetimes | WorkspaceWindowController and its runtime services |
| ProgramRuntime and Vision definition/model inputs | Last successfully persisted content, separate from in-memory confirmation |
| Live preferences | StateService, projected by the runtime coordinator |
| Local state URL and transient state migration | WorkspaceWindowController |
| Device assignments, output folders, stream keys and monitor assignments | Shared AppletData |
| Program selection | Program Inspector and controller, using injected AppletData |
| Program deletion, layer membership and resource operations | Explicit controller/runtime editing operations |
| Layer transforms, audio gains, master volumes and mute edits | Direct bindings and editors with explicit numeric encoding |
| Output, screenshot and inference commands | ViewController and runtime actions |
| Runtime error presentation | WorkspaceWindowController |
| Dock recording badge | WindowController observes output state through weakly registered controllers |

There is no Apply/Submit registry or navigation guard for unconfirmed input.
Representable edits update StateService; incomplete numeric text may remain local
to its input control. Semantic validation runs during snapshot preparation. A
validation failure leaves Document unchanged. Successful preparation confirms
the captured content in Document before writing; write failure leaves that
content unsaved. Later edits remain pending in StateService. UI adopts Document
changes through Observation, rather than callbacks from apply.

The connection updates StateService fields directly. Adopting a read snapshot
replaces the three documents, envelope IDs and model URL dictionary.
An explicit URL-only update changes existing model-ID entries without adding or deleting
entries or touching document edits. Neither operation overwrites UI selections or
runtime status. No independent field-level merge is performed.

The Coordinator is retained by the Representable, not Document. Dismantling the
representation stops UI observation and starts idempotent async
shutdown. Document can retain confirmed content independently of that UI lifetime.
