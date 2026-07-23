// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import SwiftUI

struct VideoComponentDetailPane: View {
    @Binding var compositeProgramDefinition: CompositeProgramDefinition
    @Binding var selectedSidebarItem: WorkspaceSidebarItem?
    var outputCanvas: OutputCanvasModel
    var workspaceInputDevices: [WorkspaceInputDeviceRecord]
    @State private var draftDisplayName = ""
    @FocusState private var isDisplayNameFieldFocused: Bool

    var body: some View {
        Form {
            if let selectedVideoComponentIndex {
                Section(resolvedDisplayName(for: selectedVideoComponentIndex)) {
                    TextField("Display Name", text: $draftDisplayName)
                        .textFieldStyle(.roundedBorder)
                        .focused($isDisplayNameFieldFocused)
                        .onSubmit {
                            commitDisplayName(for: selectedVideoComponentIndex)
                        }
                        .accessibilityIdentifier("videoComponentDisplayNameField")

                    ProgramComponentEditor(
                        step: compositeStepBinding(for: selectedVideoComponentIndex),
                        workspaceInputDevices: workspaceInputDevices
                    )
                }

                Section {
                    Button(role: .destructive) {
                        deleteSelectedVideoComponent(at: selectedVideoComponentIndex)
                    } label: {
                        Label("Delete Video Component", systemImage: "trash")
                    }
                    .accessibilityIdentifier("deleteVideoComponentButton")
                }
            } else {
                Section("Video Component") {
                    Text("Select a video component in the content pane.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshDraftDisplayName()
        }
        .onChange(of: selectedSidebarItem) { _, _ in
            refreshDraftDisplayName()
        }
        .onChange(of: compositeProgramDefinition.steps) { _, _ in
            guard !isDisplayNameFieldFocused else {
                return
            }
            refreshDraftDisplayName()
        }
        .onChange(of: isDisplayNameFieldFocused) { _, isFocused in
            if !isFocused, selectedVideoComponentIndex != nil {
                commitDisplayName(for: selectedVideoComponentIndex)
            }
        }
    }

    private var selectedVideoComponentIndex: Int? {
        guard case let .some(.videoComponent(id)) = selectedSidebarItem else {
            return nil
        }
        return compositeProgramDefinition.steps.firstIndex(where: { $0.id == id })
    }

    private func compositeStepBinding(for index: Int) -> Binding<CompositeProgramStep> {
        Binding(
            get: { compositeProgramDefinition.steps[index] },
            set: { compositeProgramDefinition.steps[index] = $0 }
        )
    }

    private func resolvedDisplayName(for index: Int) -> String {
        let step = compositeProgramDefinition.steps[index]
        return compositeProgramDefinition.resolvedVideoComponentDisplayName(
            for: step,
            workspaceInputDevices: workspaceInputDevices
        )
    }

    private func refreshDraftDisplayName() {
        guard let selectedVideoComponentIndex else {
            draftDisplayName = ""
            return
        }
        draftDisplayName = resolvedDisplayName(for: selectedVideoComponentIndex)
    }

    private func commitDisplayName(for index: Int?) {
        guard let index, compositeProgramDefinition.steps.indices.contains(index) else {
            return
        }

        let trimmedName = draftDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentName = compositeProgramDefinition.steps[index].name
        guard !trimmedName.isEmpty else {
            draftDisplayName = currentName
            return
        }
        guard trimmedName == currentName || !compositeProgramDefinition.steps.contains(where: {
            $0.name == trimmedName
        }) else {
            draftDisplayName = currentName
            return
        }
        guard trimmedName != currentName else {
            draftDisplayName = currentName
            return
        }

        compositeProgramDefinition.steps[index].name = trimmedName
        if selectedSidebarItem == .videoComponent(currentName) {
            selectedSidebarItem = .videoComponent(trimmedName)
        }
        draftDisplayName = trimmedName
    }

    private func deleteSelectedVideoComponent(at index: Int) {
        guard compositeProgramDefinition.steps.indices.contains(index) else {
            return
        }

        compositeProgramDefinition.steps.remove(at: index)

        if compositeProgramDefinition.steps.indices.contains(index) {
            selectedSidebarItem = .videoComponent(compositeProgramDefinition.steps[index].id)
        } else if let previous = compositeProgramDefinition.steps.indices.last {
            selectedSidebarItem = .videoComponent(compositeProgramDefinition.steps[previous].id)
        } else {
            selectedSidebarItem = .streamSettings
        }
    }
}
