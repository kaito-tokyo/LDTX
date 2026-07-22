// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspace
import SwiftUI

struct AutomationSidebarSection: View {
    @Binding var automations: [WorkspaceAutomationDefinition]
    @Binding var selectedSidebarItem: WorkspaceSidebarItem?
    let inputDevices: [WorkspaceInputDeviceRecord]
    let visions: [WorkspaceVisionDefinition]
    let isEnabled: Bool
    @State private var isShowingAddDialog = false
    @State private var proposedName = ""

    var body: some View {
        Section {
            ForEach(Array(automations.enumerated()), id: \.element.name) { index, automation in
                AutomationSidebarRow(
                    automation: automation,
                    isEnabled: isEnabled,
                    nameIsAvailable: { candidate in
                        WorkspaceResourceNameValidator.isAvailable(
                            candidate, inputDevices: inputDevices, visions: visions,
                            automations: automations, excludingResourceID: automation.name
                        )
                    },
                    select: { selectedSidebarItem = .automation(automation.name) },
                    rename: { automations[index].name = $0 }
                )
                .tag(WorkspaceSidebarItem.automation(automation.name))
            }
        } header: {
            WorkspaceSidebarSectionHeader(
                title: "Automation", accessibilityIdentifier: "addWorkspaceAutomationButton",
                isAddEnabled: isEnabled, add: beginAddingAutomation
            )
        }
        .sheet(isPresented: $isShowingAddDialog) {
            ItemNameDialog(
                name: $proposedName,
                title: "Add Automation",
                fieldTitle: "Automation Name",
                isNameAvailable: nameIsAvailable,
                submit: addAutomation(named:),
                cancel: { isShowingAddDialog = false }
            )
        }
    }

    private func beginAddingAutomation() {
        proposedName = WorkspaceResourceNameValidator.uniqueName(
            base: "Automation", inputDevices: inputDevices, visions: visions, automations: automations
        )
        isShowingAddDialog = true
    }

    private func nameIsAvailable(_ name: String) -> Bool {
        WorkspaceResourceNameValidator.isAvailable(
            name, inputDevices: inputDevices, visions: visions, automations: automations
        )
    }

    private func addAutomation(named name: String) {
        guard nameIsAvailable(name) else { return }
        automations.append(WorkspaceAutomationDefinition(name: name))
        selectedSidebarItem = .automation(name)
        isShowingAddDialog = false
    }
}

private struct AutomationSidebarRow: View {
    let automation: WorkspaceAutomationDefinition
    let isEnabled: Bool
    let nameIsAvailable: (String) -> Bool
    let select: () -> Void
    let rename: (String) -> Void
    @State private var renameSession: InlineRenameSession?
    @FocusState private var renameFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt").foregroundStyle(.secondary).frame(width: 16)
            if renameSession != nil {
                TextField("Automation Name", text: draftBinding)
                    .textFieldStyle(.plain).focused($renameFocused).onSubmit(commitRename)
                    .onExitCommand { renameSession = nil }
            } else {
                Text(automation.name).lineLimit(1)
                    .foregroundStyle(automation.isEnabled ? .primary : .secondary)
            }
            Spacer(minLength: 8)
            SidebarActionButton(
                systemImage: "pencil", accessibilityLabel: "Rename Automation",
                accessibilityIdentifier: "workspaceAutomationRenameButton-\(automation.name)"
            ) { beginRename() }.disabled(!isEnabled)
        }
        .contentShape(Rectangle()).onTapGesture(perform: select)
    }

    private var draftBinding: Binding<String> {
        Binding(get: { renameSession?.draft ?? "" }, set: { renameSession?.draft = $0 })
    }
    private func beginRename() {
        select(); renameSession = InlineRenameSession(originalName: automation.name, draft: automation.name)
        renameFocused = true
    }
    private func commitRename() {
        guard let session = renameSession else { return }
        let candidate = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, nameIsAvailable(candidate) else { return }
        rename(candidate); renameSession = nil
    }
}
