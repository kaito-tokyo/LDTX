// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import SwiftUI

struct MainSidebarPane: View {
    @Binding var mainWindowState: MainWindowState
    @Binding var programLibrary: ProgramLibrary
    var selectProgramDefinition: (_ name: String?) -> Void
    var renameProgramDefinition: (_ oldName: String, _ newName: String) -> Void
    var deleteProgramDefinition: (_ name: String) -> Void
    @State private var pendingDeleteProgramName: String?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: programSidebarSelection) {
                Section("Programs") {
                    Label("New Program", systemImage: "doc.badge.plus")
                        .accessibilityIdentifier("scratchPadProgramDefinitionRow")
                        .tag(ProgramSidebarSelection.scratchPad)

                    if programLibrary.records.isEmpty {
                        Text("No saved programs")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(programLibrary.records, id: \.name) { definition in
                            ProgramSidebarNameRow(
                                name: definition.name,
                                rename: { newName in
                                    renameProgramDefinition(definition.name, newName)
                                },
                                requestDelete: {
                                    pendingDeleteProgramName = definition.name
                                }
                            )
                            .tag(ProgramSidebarSelection.saved(definition.name))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .navigationTitle("Programs")
        .confirmationDialog(
            "Delete Program?",
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible,
            presenting: pendingDeleteProgramName
        ) { name in
            Button("Delete", role: .destructive) {
                deleteProgramDefinition(name)
                pendingDeleteProgramName = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteProgramName = nil
            }
        } message: { name in
            Text("Delete \"\(name)\"?")
        }
    }

    private var programSidebarSelection: Binding<ProgramSidebarSelection?> {
        Binding(
            get: {
                if let selectedName = mainWindowState.selectedSavedProgramDefinitionName {
                    return .saved(selectedName)
                }
                return .scratchPad
            },
            set: { selection in
                switch selection {
                case .scratchPad, .none:
                    mainWindowState.selectedSidebarItem = .program
                    selectProgramDefinition(nil)
                case let .saved(name):
                    mainWindowState.selectedSidebarItem = .program
                    selectProgramDefinition(name)
                }
            }
        )
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteProgramName != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeleteProgramName = nil
                }
            }
        )
    }
}

private enum ProgramSidebarSelection: Hashable {
    case scratchPad
    case saved(String)
}

private struct ProgramSidebarNameRow: View {
    var name: String
    var rename: (String) -> Void
    var requestDelete: () -> Void
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(name: String, rename: @escaping (String) -> Void, requestDelete: @escaping () -> Void) {
        self.name = name
        self.rename = rename
        self.requestDelete = requestDelete
        _text = State(initialValue: name)
    }

    var body: some View {
        HStack(spacing: 8) {
            Label {
                TextField("Program Name", text: $text)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("savedProgramDefinitionNameField.\(name)")
                    .focused($isFocused)
                    .onSubmit {
                        commit()
                    }
                    .onChange(of: isFocused) { _, newValue in
                        if !newValue {
                            commit()
                        }
                    }
                    .onChange(of: name) { _, newValue in
                        if !isFocused {
                            text = newValue
                        }
                    }
            } icon: {
                Image(systemName: "rectangle.stack")
            }
            Spacer(minLength: 4)
            Button(role: .destructive, action: requestDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete Program")
            .accessibilityLabel("Delete Program")
            .accessibilityIdentifier("deleteSavedProgramDefinitionButton.\(name)")
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            text = name
            return
        }
        if trimmed != name {
            rename(trimmed)
        }
    }
}
