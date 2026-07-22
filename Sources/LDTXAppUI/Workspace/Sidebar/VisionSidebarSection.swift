// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspace
import SwiftUI

struct VisionSidebarSection: View {
    @Binding var visions: [WorkspaceVisionDefinition]
    @Binding var selectedSidebarItem: WorkspaceSidebarItem?
    let inputDevices: [WorkspaceInputDeviceRecord]
    let automations: [WorkspaceAutomationDefinition]
    let isEnabled: Bool
    @State private var isShowingAddDialog = false
    @State private var proposedName = ""

    var body: some View {
        Section {
            ForEach(Array(visions.enumerated()), id: \.element.name) { index, vision in
                VisionSidebarRow(
                    vision: vision,
                    isEnabled: isEnabled,
                    nameIsAvailable: { candidate in
                        WorkspaceResourceNameValidator.isAvailable(
                            candidate,
                            inputDevices: inputDevices,
                            visions: visions,
                            automations: automations,
                            excludingResourceID: vision.name
                        )
                    },
                    select: { selectedSidebarItem = .vision(vision.name) },
                    rename: { newName in visions[index].name = newName }
                )
                .tag(WorkspaceSidebarItem.vision(vision.name))
            }
        } header: {
            WorkspaceSidebarSectionHeader(
                title: "Vision",
                accessibilityIdentifier: "addWorkspaceVisionButton",
                isAddEnabled: isEnabled,
                add: beginAddingVision
            )
        }
        .sheet(isPresented: $isShowingAddDialog) {
            ItemNameDialog(
                name: $proposedName,
                title: "Add Vision",
                fieldTitle: "Vision Name",
                isNameAvailable: nameIsAvailable,
                submit: addVision(named:),
                cancel: { isShowingAddDialog = false }
            )
        }
    }

    private func beginAddingVision() {
        proposedName = WorkspaceResourceNameValidator.uniqueName(
            base: "Vision", inputDevices: inputDevices, visions: visions, automations: automations
        )
        isShowingAddDialog = true
    }

    private func nameIsAvailable(_ name: String) -> Bool {
        WorkspaceResourceNameValidator.isAvailable(
            name, inputDevices: inputDevices, visions: visions, automations: automations
        )
    }

    private func addVision(named name: String) {
        guard nameIsAvailable(name) else { return }
        visions.append(WorkspaceVisionDefinition(name: name))
        selectedSidebarItem = .vision(name)
        isShowingAddDialog = false
    }
}

private struct VisionSidebarRow: View {
    let vision: WorkspaceVisionDefinition
    let isEnabled: Bool
    let nameIsAvailable: (String) -> Bool
    let select: () -> Void
    let rename: (String) -> Void
    @State private var renameSession: InlineRenameSession?
    @FocusState private var renameFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye").foregroundStyle(.secondary).frame(width: 16)
            if renameSession != nil {
                TextField("Vision Name", text: draftBinding)
                    .textFieldStyle(.plain).focused($renameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { renameSession = nil }
                    .accessibilityIdentifier("workspaceSidebarVisionNameField")
            } else {
                Text(vision.name).lineLimit(1)
            }
            Spacer(minLength: 8)
            SidebarActionButton(
                systemImage: "pencil",
                accessibilityLabel: "Rename Vision",
                accessibilityIdentifier: "workspaceVisionRenameButton-\(vision.name)"
            ) { beginRename() }
            .disabled(!isEnabled)
        }
        .contentShape(Rectangle()).onTapGesture(perform: select)
    }

    private var draftBinding: Binding<String> {
        Binding(get: { renameSession?.draft ?? "" }, set: { renameSession?.draft = $0 })
    }
    private func beginRename() {
        select(); renameSession = InlineRenameSession(originalName: vision.name, draft: vision.name)
        renameFocused = true
    }
    private func commitRename() {
        guard let session = renameSession else { return }
        let candidate = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, nameIsAvailable(candidate) else { return }
        rename(candidate); renameSession = nil
    }
}
