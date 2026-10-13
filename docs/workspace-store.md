<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Workspace state responsibility inventory

WorkspaceStateService holds editable protobuf values and observable UI/runtime
facts for one Workspace editor. WorkspaceWindowController owns it. Document holds
confirmed content and file persistence, not the editor or an editing copy.
Assignments to StateService's stored properties remain transparent; direct
Bindable access does not hide validation, persistence, or runtime synchronization.

| Responsibility | Owner |
| --- | --- |
| Confirmed definition, preferences, output settings and embedded models | WorkspaceDocument |
| Editable definition, preferences, output settings and pending model selections | WorkspaceStateService, owned by WindowController |
| UI selection, Inspector visibility, output and Vision status | WorkspaceStateService |
| Reading, snapshot validation, writing and verification at the formal URL | WorkspaceDocument and its Reader/Writer |
| Snapshot capture and read/save reconciliation with the editor | Representable Coordinator; weak connection from Document |
| Undo/Redo and standard unsaved-change tracking | Representable Coordinator and the window's UndoManager |
| Runtime projection and recording/capture/audio/Vision lifetimes | WorkspaceWindowController and its runtime services |
| ProgramRuntime and Vision definition/model inputs | Document's confirmed content |
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
to its input control. Semantic validation runs when saving. A failed save retains
the edits and leaves confirmed content unchanged. On success, only the saved
snapshot becomes confirmed; later edits remain pending in StateService.

The Coordinator is retained by the Representable, not Document. Dismantling the
representation disconnects the editing endpoint and starts idempotent async
shutdown. Document can retain confirmed content independently of that UI lifetime.
