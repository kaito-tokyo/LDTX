// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import SwiftUI

/// Edits the Workspace's Program catalogue separately from scene selection.
/// The selected Program is intentionally not deletable: it is the Program
/// currently projected into the editor (or selected for output).
struct ProgramManagementSheet: View {
  let programs: [SavedProgramDefinitionRecord]
  let selectedProgramName: String?
  let addProgram: (String) -> Void
  let renameProgram: (String, String) -> Bool
  let deleteProgram: (String) -> Void
  let moveProgram: (String, Int) -> Void
  let dismiss: () -> Void

  @State private var proposedNewProgramName = ""
  @State private var renameTarget: String?
  @State private var proposedRename = ""
  @State private var deleteTarget: String?
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case newProgram
    case renameProgram
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Manage Programs")
          .font(.title2.bold())
        Text(
          "Programs define the scenes available for selection. Reorder them here; the current Program cannot be deleted."
        )
        .foregroundStyle(.secondary)
      }

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

      Divider()

      HStack(spacing: 10) {
        TextField("New Program", text: $proposedNewProgramName)
          .focused($focusedField, equals: .newProgram)
          .onSubmit(addProgramIfValid)
          .accessibilityIdentifier("newProgramNameField")
        Button("Add", action: addProgramIfValid)
          .disabled(!canAddProgram)
          .accessibilityIdentifier("addProgramFromManagementButton")
      }

      HStack {
        Spacer()
        Button("Done", action: dismiss)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 560)
    .onAppear {
      focusedField = .newProgram
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
    focusedField = .newProgram
  }

  private func renameProgramIfValid() {
    guard let renameTarget, canRenameProgram else { return }
    if renameProgram(renameTarget, trimmedRename) {
      self.renameTarget = nil
      dismiss()
    }
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
    ProgramManagementSheet(
      programs: LDTXAppUIPreviewFixtures.programRecords,
      selectedProgramName: LDTXAppUIPreviewFixtures.selectedProgramDefinitionName,
      addProgram: { _ in },
      renameProgram: { _, _ in true },
      deleteProgram: { _ in },
      moveProgram: { _, _ in },
      dismiss: {}
    )
  }
#endif
