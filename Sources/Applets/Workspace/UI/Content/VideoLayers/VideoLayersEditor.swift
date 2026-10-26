// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXCorelibs
import LDTXWorkspaceAppletModel
import Observation
import SwiftUI

@MainActor @Observable
final class VideoLayersEditorState {
  let stateService: WorkspaceDocument
  let appletData: WorkspaceAppletData
  let target: WorkspaceCanvasTarget
  private(set) var rows: [Int64: VideoLayersTableRowState] = [:]
  var failure: String?

  var programID: Int64? {
    appletData.selectedProgram(
      in: stateService.workspaceDefinition, for: stateService.localStateURL)?.internalID
  }
  var preferences: Ldtx_Workspace_V4_ProgramPreferences {
    programID.flatMap { stateService.workspacePreferences[keyPath: target.preferences][$0] }
      ?? .init()
  }
  var layerIDs: [Int64] { preferences.videoLayerInternalIds }

  private var displayedProgramID: Int64?
  init(
    stateService: WorkspaceDocument, appletData: WorkspaceAppletData,
    target: WorkspaceCanvasTarget
  ) {
    self.stateService = stateService
    self.appletData = appletData
    self.target = target
    synchronizeRows()
  }

  func move(
    fromOffsets source: IndexSet, toOffset destination: Int, undoManager: UndoManager? = nil
  ) {
    guard let programID,
      !source.isEmpty,
      source.allSatisfy({ layerIDs.indices.contains($0) }),
      (0...layerIDs.count).contains(destination)
    else { return }
    var order = layerIDs
    order.move(fromOffsets: source, toOffset: destination)
    do {
      try commitLayerOrder(order, programID: programID, undoManager: undoManager)
      failure = nil
    } catch {
      failure = error.localizedDescription
    }
  }

  func commitLayerOrder(_ ids: [Int64], programID: Int64, undoManager: UndoManager? = nil) throws {
    guard stateService.workspaceDefinition.programs.contains(where: { $0.internalID == programID })
    else { throw WorkspaceSelectionError(message: "The Program is unavailable.") }
    let current =
      stateService.workspacePreferences[keyPath: target.preferences][programID]?
      .videoLayerInternalIds ?? []
    guard current.sorted() == ids.sorted() else {
      throw WorkspaceSelectionError(message: "The video layer order changed.")
    }
    stateService.editWorkspace(undoManager: undoManager) { workspace in
      workspace.preferences[keyPath: target.preferences][programID, default: .init()]
        .videoLayerInternalIds = ids
    }
  }

  func synchronizeRows() {
    if displayedProgramID != programID {
      rows = [:]
      failure = nil
      displayedProgramID = programID
    }
    rows = rows.filter { layerIDs.contains($0.key) }
    let program = programID
    for id in layerIDs {
      let row = rows[id] ?? VideoLayersTableRowState()
      let component = stateService.workspaceDefinition.videoComponents.first { $0.internalID == id }
      row.name = component?.displayName ?? "Missing Video Layer"
      switch component?.videoComponent {
      case .vfxSource, .clock, .dynamicText: row.supportsPlacement = true
      default: row.supportsPlacement = false
      }
      row.isHidden = preferences.videoLayerHidden[id] ?? false
      if !row.hasLocalTextChanges && !row.isEditing {
        row.display(
          preferences.videoLayerTransforms[id] ?? .init(), canvasWidth: 1920, canvasHeight: 1080)
      }
      row.onCommit = { [weak self, weak row] undoManager in
        guard let self, let row, row.hasLocalTextChanges, let program,
          self.programID == program,
          self.rows[id] === row,
          self.stateService.workspacePreferences[keyPath: self.target.preferences][program]?
            .videoLayerInternalIds.contains(id) == true
        else { return }
        let (transform, incomplete) = self.parsedTransform(for: row)
        let previous = row.transform
        if (transform.translationX?.double(defaultNumerator: 0, defaultDenominator: 1) ?? 0)
          == (previous.translationX?.double(defaultNumerator: 0, defaultDenominator: 1) ?? 0),
          (transform.translationY?.double(defaultNumerator: 0, defaultDenominator: 1) ?? 0)
            == (previous.translationY?.double(defaultNumerator: 0, defaultDenominator: 1) ?? 0),
          (transform.scaleX?.double(defaultNumerator: 1, defaultDenominator: 1) ?? 1)
            == (previous.scaleX?.double(defaultNumerator: 1, defaultDenominator: 1) ?? 1),
          (transform.scaleY?.double(defaultNumerator: 1, defaultDenominator: 1) ?? 1)
            == (previous.scaleY?.double(defaultNumerator: 1, defaultDenominator: 1) ?? 1)
        {
          row.hasLocalTextChanges = incomplete
          return
        }
        self.stateService.editWorkspace(undoManager: undoManager) { workspace in
          workspace.preferences[keyPath: self.target.preferences][program, default: .init()]
            .videoLayerTransforms[id] = transform
        }
        row.transform = transform
        row.hasLocalTextChanges = incomplete
      }
      row.onSetHidden = { [weak self, weak row] hidden, undoManager in
        guard let self, let row, let program, self.programID == program,
          self.rows[id] === row,
          self.stateService.workspacePreferences[keyPath: self.target.preferences][program]?
            .videoLayerInternalIds.contains(id) == true
        else { return }
        self.stateService.editWorkspace(undoManager: undoManager) { workspace in
          workspace.preferences[keyPath: self.target.preferences][program, default: .init()]
            .videoLayerHidden[id] = hidden
        }
        row.isHidden = hidden
      }
      rows[id] = row
    }
  }

  private func parsedTransform(for state: VideoLayersTableRowState)
    -> (Ldtx_Workspace_V4_BasicTransform, Bool)
  {
    var hasIncompleteText = false
    let previous = state.transform
    let fallback = [
      previous.translationX ?? .init(), previous.translationY ?? .init(),
      Ldtx_Workspace_V4_Rational32.with {
        $0.set(num: previous.scaleX?.num ?? 1, den: previous.scaleX?.den ?? 1)
      },
      Ldtx_Workspace_V4_Rational32.with {
        $0.set(num: previous.scaleY?.num ?? 1, den: previous.scaleY?.den ?? 1)
      },
    ]
    let values = state.strings.enumerated().map { index, text in
      do {
        if index < 2 {
          let size = UInt32(index == 0 ? 1920 : 1080)
          guard let pixels = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
          else {
            throw WorkspaceSelectionError(
              message: "Enter an integer pixel position.")
          }
          var value = Ldtx_Workspace_V4_Rational32()
          value.set(num: pixels, den: size)
          return value
        }
        guard !text.contains("/") else {
          throw WorkspaceSelectionError(message: "Enter a decimal scale.")
        }
        guard
          let decimal = Decimal(
            string: text.trimmingCharacters(in: .whitespacesAndNewlines),
            locale: Locale(identifier: "en_US_POSIX")),
          (try? RationalParseStrategy().parse(text)) != nil
        else { throw RationalInputError.invalidNumber }
        var value = Ldtx_Workspace_V4_Rational32()
        try value.set(decimal: decimal)
        return value
      } catch {
        hasIncompleteText = true
        return fallback[index]
      }
    }
    var transform = state.transform
    transform.translationX = values[0]
    transform.translationY = values[1]
    transform.scaleX = .init(value: values[2])
    transform.scaleY = .init(value: values[3])
    return (transform, hasIncompleteText)
  }

}

struct VideoLayersEditor: View {
  @Environment(\.undoManager) private var undoManager
  let editor: VideoLayersEditorState

  var body: some View {
    Section {
      ForEach(editor.layerIDs, id: \.self) { id in
        if let row = editor.rows[id] {
          VideoLayersTableRowContent(
            state: row, canvasWidth: 1920, canvasHeight: 1080
          )
        }
      }
      .onMove { editor.move(fromOffsets: $0, toOffset: $1, undoManager: undoManager) }
      if let message = editor.failure ?? editor.stateService.outputFailureMessage {
        Text(message).foregroundStyle(.secondary)
      } else if editor.programID == nil {
        Text("No program selected").foregroundStyle(.secondary)
      } else if editor.layerIDs.isEmpty {
        Text("No video layers").foregroundStyle(.secondary)
      }
    } header: {
      Text("Video Layers")
    }
    .id(editor.programID)
    .onChange(of: editor.programID, initial: true) { _, _ in
      editor.synchronizeRows()
    }
    .onChange(of: editor.preferences) { _, _ in editor.synchronizeRows() }
    .onChange(of: editor.stateService.workspaceDefinition) { _, _ in editor.synchronizeRows() }
  }

}
