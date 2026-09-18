// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import SwiftUI

/// Edits the Workspace's Program catalogue separately from scene selection.
/// The selected Program is intentionally not deletable: it is the Program
/// currently projected into the editor (or selected for output).
struct ProgramManagementPane: View {
  let programs: [SavedProgramDefinitionRecord]
  let selectedProgramName: String?
  let addProgram: (String) -> Void
  let renameProgram: (String, String) -> Bool
  let deleteProgram: (String) -> Void
  let moveProgram: (String, Int) -> Void

  @State private var proposedNewProgramName = ""
  @State private var isShowingAddProgramDialog = false
  @State private var renameTarget: String?
  @State private var proposedRename = ""
  @State private var deleteTarget: String?
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case renameProgram
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      List {
        ForEach(Array(programs.enumerated()), id: \.element.name) { index, program in
          ProgramManagementRow(
            name: program.name,
            isSelected: program.name == selectedProgramName,
            canMoveUp: index > 0,
            canMoveDown: index < programs.count - 1,
            moveUp: { moveProgram(program.name, -1) },
            moveDown: { moveProgram(program.name, 1) },
            rename: {
              renameTarget = program.name
              proposedRename = program.name
              focusedField = .renameProgram
            },
            delete: { deleteTarget = program.name }
          )
        }
      }
      .listStyle(.inset)
      .frame(minHeight: 180, maxHeight: 300)
      .accessibilityIdentifier("programManagementList")
    }
    .padding(24)
    .frame(maxWidth: 680, maxHeight: .infinity, alignment: .topLeading)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          proposedNewProgramName = ""
          isShowingAddProgramDialog = true
        } label: {
          Label("Add Program", systemImage: "plus")
        }
        .help("Add Program")
        .accessibilityIdentifier("addProgramFromManagementButton")
      }
    }
    .sheet(isPresented: $isShowingAddProgramDialog) {
      AddProgramDialog(
        name: $proposedNewProgramName,
        existingNames: Set(programs.map(\.name)),
        add: addProgramIfValid,
        cancel: { isShowingAddProgramDialog = false }
      )
    }
    .alert("Rename Program", isPresented: renamePresented) {
      TextField("New Name", text: $proposedRename)
      Button("Cancel", role: .cancel) {
        renameTarget = nil
      }
      Button("Rename") {
        renameProgramIfValid()
      }
      .disabled(!canRenameProgram)
    } message: {
      Text(
        "Renaming saves and reopens the Workspace because Program names are used by scene selection."
      )
    }
    .confirmationDialog(
      "Delete Program?",
      isPresented: deletePresented,
      titleVisibility: .visible
    ) {
      Button("Delete \(deleteTarget ?? "Program")", role: .destructive) {
        if let deleteTarget {
          deleteProgram(deleteTarget)
        }
        self.deleteTarget = nil
      }
      Button("Cancel", role: .cancel) {
        deleteTarget = nil
      }
    } message: {
      Text("This cannot be undone.")
    }
  }

  private var trimmedNewProgramName: String {
    proposedNewProgramName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canAddProgram: Bool {
    !trimmedNewProgramName.isEmpty && !programs.contains { $0.name == trimmedNewProgramName }
  }

  private var renamePresented: Binding<Bool> {
    Binding(
      get: { renameTarget != nil },
      set: { isPresented in
        if !isPresented { renameTarget = nil }
      }
    )
  }

  private var deletePresented: Binding<Bool> {
    Binding(
      get: { deleteTarget != nil },
      set: { isPresented in
        if !isPresented { deleteTarget = nil }
      }
    )
  }

  private var trimmedRename: String {
    proposedRename.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canRenameProgram: Bool {
    guard let renameTarget else { return false }
    return !trimmedRename.isEmpty
      && trimmedRename != renameTarget
      && !programs.contains { $0.name == trimmedRename }
  }

  private func addProgramIfValid() {
    guard canAddProgram else { return }
    addProgram(trimmedNewProgramName)
    proposedNewProgramName = ""
    isShowingAddProgramDialog = false
  }

  private func renameProgramIfValid() {
    guard let renameTarget, canRenameProgram else { return }
    if renameProgram(renameTarget, trimmedRename) {
      self.renameTarget = nil
    }
  }
}

private struct AddProgramDialog: View {
  @Binding var name: String
  let existingNames: Set<String>
  let add: () -> Void
  let cancel: () -> Void
  @FocusState private var isNameFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Add Program")
        .font(.title2.bold())

      TextField("Name", text: $name)
        .focused($isNameFocused)
        .onSubmit { if canAdd { add() } }
        .accessibilityIdentifier("newProgramNameField")

      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: cancel)
        Button("Add", action: add)
          .keyboardShortcut(.defaultAction)
          .disabled(!canAdd)
      }
    }
    .padding(24)
    .frame(width: 420)
    .onAppear { isNameFocused = true }
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canAdd: Bool {
    !trimmedName.isEmpty && !existingNames.contains(trimmedName)
  }
}

private struct ProgramManagementRow: View {
  let name: String
  let isSelected: Bool
  let canMoveUp: Bool
  let canMoveDown: Bool
  let moveUp: () -> Void
  let moveDown: () -> Void
  let rename: () -> Void
  let delete: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: isSelected ? "checkmark.circle.fill" : "rectangle.on.rectangle")
        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        .frame(width: 16)
      Text(name)
      if isSelected {
        Text("Current")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button(action: moveUp) {
        Label("Move Up", systemImage: "arrow.up")
      }
      .labelStyle(.iconOnly)
      .disabled(!canMoveUp)
      .accessibilityIdentifier("moveProgramUpButton-\(name)")
      Button(action: moveDown) {
        Label("Move Down", systemImage: "arrow.down")
      }
      .labelStyle(.iconOnly)
      .disabled(!canMoveDown)
      .accessibilityIdentifier("moveProgramDownButton-\(name)")
      Button(action: rename) {
        Label("Rename Program", systemImage: "pencil")
      }
      .labelStyle(.iconOnly)
      .accessibilityIdentifier("renameProgramButton-\(name)")
      Button(role: .destructive, action: delete) {
        Label("Delete Program", systemImage: "trash")
      }
      .labelStyle(.iconOnly)
      .disabled(isSelected)
      .help(isSelected ? "The current Program cannot be deleted." : "Delete Program")
      .accessibilityIdentifier("deleteProgramButton-\(name)")
    }
    .accessibilityElement(children: .contain)
  }
}

#if DEBUG
  #Preview("Program Management") {
    ProgramManagementPane(
      programs: LDTXAppUIPreviewFixtures.programRecords,
      selectedProgramName: LDTXAppUIPreviewFixtures.selectedProgramDefinitionName,
      addProgram: { _ in },
      renameProgram: { _, _ in true },
      deleteProgram: { _ in },
      moveProgram: { _, _ in }
    )
  }
#endif
