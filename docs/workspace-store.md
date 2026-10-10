<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Workspace Store responsibility inventory

The Store is the observable source of truth. Its Workspace documents are
ordinary stored properties; direct Bindable access must not invoke hidden
editing policies. The Store retains Workspace documents and observable UI/runtime
facts. Editing policy, persistence and operations belong to explicit owners.

| Responsibility | Current status | Owner |
| --- | --- | --- |
| Workspace definition, preferences, output settings | Transparent stored properties | Store |
| Local state URL | Document updates its adopted or transient URL explicitly; Store has no Document reference | Document |
| Unsaved document changes | Observed outside the Store | Document |
| Audio monitor, runtime and mix synchronization; output pause/stop | Redundant forwarding methods removed | Controller/runtime actions |
| Screenshot-directory forwarding and audio-mix selection helper | Unused Store methods removed | Owning controller and direct UI state binding |
| Inspector selection | Transparent stored property; Sidebar owns rejection and its callback | Sidebar |
| Apply invocation | Request flag and its observation removed; Window invokes Submit directly | Window |
| Unconfirmed edits | Document owns WorkspaceEditingState; Window, Controller, Sidebar and editors receive it explicitly | Document and editing UI |
| Program rename | Validation and writeback moved to its Inspector | Program editor |
| Program selection | Store forwarding and selectedProgram projection removed; all consumers resolve selection through injected AppletData | Program Inspector/controller |
| Program deletion | Store forwarding removed; Controller owns validation and deletion | Controller |
| Program preferences and layer membership/transform editing | Store methods removed; editors write their fields directly | Bindings and editor-owned validation |
| Audio gain, master volume and mute edits | Generic Store update removed; editors write the model directly | Audio editors with explicit quantization |
| Runtime operations | Store runtimeActions reference removed; owning UI receives the Controller directly through weak providers | Controller and composition root |
| App-local state | Store AppletData reference and localState projection removed; owners receive AppletData directly | AppletData and composition roots |
| Monitor configuration | Audio editors receive AppletData directly and use localStateURL; Document reference and monitor eligibility helper removed | Monitor editor/AppletData |
| Capture synchronization | Store forwarding removed | Controller and invoking UI |
| Screenshots | Store forwarding removed; Window handles availability | Window/controller |
| Output start | Store forwarding removed | Window/controller |
| Save validation | Store methods removed; Document validates its snapshot | Document and integrity validator |
| Audio peak meter | Coordinator owns it; injected directly through Window and Content Pane | Audio coordinator/editors |
| Error presentation | Store error APIs removed; AppKit callbacks and SwiftUI Environment route errors to Controller | Window/document presentation owners |
| Output, recording and Vision status | Observable facts remain; Dock observes output state in Document | Store, populated by runtime owner |

No migration references or operational forwarding methods remain in the Store.
Model editing uses the same authoritative Proto documents; Bindable access does
not perform validation, persistence or runtime synchronization. Document and
Controller observe those values, and editing owners validate their own inputs.
