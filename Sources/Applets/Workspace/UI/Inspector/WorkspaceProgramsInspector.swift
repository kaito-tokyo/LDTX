// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppletSupport
import LDTXProtos
import LDTXWorkspaceAppletInterface
import SwiftUI

struct WorkspaceProgramSelector: View {
  let programs: [Ldtx_Workspace_V4_ProgramDefinition]
  @Binding var selection: UInt64?

  var body: some View {
    if programs.isEmpty {
      Text("No Program").foregroundStyle(.secondary)
    } else {
      Picker("Program", selection: $selection) {
        ForEach(programs, id: \.internalID) {
          Text($0.displayName).tag(Optional($0.internalID))
        }
      }
      .pickerStyle(.radioGroup)
    }
  }
}

struct WorkspaceProgramsInspector: View {
  @Environment(\.documentReference) private var documentReference
  let storeService: WorkspaceStoreService
  @Bindable var appletData: WorkspaceAppletData

  private struct ActionTarget: Identifiable {
    let id: UInt64
    let name: String
  }
  @State private var renameTarget: ActionTarget?
  @State private var nameDraft = ""
  @State private var deleteTarget: ActionTarget?
  @State private var showsDeleteConfirmation = false

  private var workspaceURL: URL? {
    guard let document = documentReference?.document else { return nil }
    return document.fileURL ?? storeService.localStateURL
  }

  var canSelectProgram: Bool { workspaceURL != nil && storeService.recordingState.canSelectProgram }

  var body: some View {
    Form {
      WorkspaceProgramSelector(
        programs: storeService.definition.programs, selection: programSelection
      )
      .disabled(!canSelectProgram)
      ForEach(storeService.definition.programs, id: \.internalID) { program in
        HStack {
          Text(program.displayName)
          Spacer()
          Button("Rename…") {
            nameDraft = program.displayName
            renameTarget = ActionTarget(id: program.internalID, name: program.displayName)
          }
          Button("Delete…", role: .destructive) {
            deleteTarget = ActionTarget(id: program.internalID, name: program.displayName)
            showsDeleteConfirmation = true
          }
        }
        .disabled(storeService.isOutputActive)
      }
      Button("Add Program") { addProgram() }
        .disabled(storeService.isOutputActive)
    }
    .formStyle(.grouped)
    .sheet(item: $renameTarget) { target in
      ItemNameDialog(
        name: $nameDraft, title: "Rename Program", fieldTitle: "Name", submitTitle: "Rename",
        isNameAvailable: { name in
          var definition = storeService.definition
          definition.programs.removeAll { $0.internalID == target.id }
          return !WorkspaceResourceAddition.existingNames(definition).contains(name)
        },
        submit: { name in
          do {
            try storeService.renameProgram(internalID: target.id, name: name)
            renameTarget = nil
          } catch { storeService.reportError(error) }
        }, cancel: { renameTarget = nil })
    }
    .alert("Delete Program?", isPresented: $showsDeleteConfirmation, presenting: deleteTarget) {
      target in
      Button("Delete", role: .destructive) {
        do { try storeService.removeProgram(internalID: target.id) } catch {
          storeService.reportError(error)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { target in
      Text("Delete “\(target.name)” and its saved preferences? This cannot be undone.")
    }
  }

  private func addProgram() {
    let id = nextInternalID()
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = id
    program.displayName = uniqueProgramDisplayName("Program")
    var definition = storeService.definition
    definition.programs.append(program)
    storeService.definition = definition
    if let workspaceURL {
      var state = appletData.state(for: workspaceURL)
      if state.selectedProgramInternalID == nil {
        state.selectedProgramInternalID = id
        appletData.setState(state, for: workspaceURL)
        storeService.updateProgramRuntimes()
      }
    }
    storeService.synchronizeAudioMonitor()
  }
  private func nextInternalID() -> UInt64 { WorkspaceResourceFactory.nextInternalID() }

  func uniqueProgramDisplayName(_ base: String) -> String {
    let names = WorkspaceResourceAddition.existingNames(storeService.definition)
    guard names.contains(base) else { return base }
    var suffix = 2
    while names.contains("\(base) \(suffix)") { suffix += 1 }
    return "\(base) \(suffix)"
  }

  var programSelection: Binding<UInt64?> {
    Binding(
      get: {
        let selectedID =
          workspaceURL.map { appletData.state(for: $0).selectedProgramInternalID } ?? nil
        return
          (storeService.definition.programs.first { $0.internalID == selectedID }
          ?? storeService.definition.programs.first)?.internalID
      },
      set: { id in
        guard let id, workspaceURL != nil else { return }
        do {
          try storeService.selectProgram(internalID: id)
        } catch { storeService.reportError(error) }
      })
  }
}
