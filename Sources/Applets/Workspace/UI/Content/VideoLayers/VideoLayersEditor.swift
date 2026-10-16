// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import LDTXWorkspaceAppletModel
import Observation
import SwiftUI

@MainActor @Observable
final class VideoLayersEditorState {
  let stateService: WorkspaceStateService
  let appletData: WorkspaceAppletData
  let target: WorkspaceCanvasTarget
  private var dragScope = UUID()
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
    stateService: WorkspaceStateService, appletData: WorkspaceAppletData,
    target: WorkspaceCanvasTarget
  ) {
    self.stateService = stateService
    self.appletData = appletData
    self.target = target
    synchronizeRows()
  }

  func token(for id: Int64) -> String {
    "\(dragScope):\(programID ?? 0):\(id)"
  }

  func move(_ tokens: [String], before destination: Int64?) -> Bool {
    guard tokens.count == 1, let source = layerIDs.first(where: { token(for: $0) == tokens[0] }),
      let programID
    else { return false }
    var order = layerIDs
    order.removeAll { $0 == source }
    if let destination {
      if destination == source { return true }
      guard let index = order.firstIndex(of: destination) else { return false }
      order.insert(source, at: index)
    } else {
      order.append(source)
    }
    do {
      try commitLayerOrder(order, programID: programID)
      return true
    } catch {
      failure = error.localizedDescription
      return false
    }
  }

  func commitLayerOrder(_ ids: [Int64], programID: Int64) throws {
    guard stateService.workspaceDefinition.programs.contains(where: { $0.internalID == programID })
    else { throw WorkspaceSelectionError(message: "The Program is unavailable.") }
    let current =
      stateService.workspacePreferences[keyPath: target.preferences][programID]?
      .videoLayerInternalIds ?? []
    guard current.sorted() == ids.sorted() else {
      throw WorkspaceSelectionError(message: "The video layer order changed.")
    }
    stateService.workspacePreferences[keyPath: target.preferences][programID, default: .init()]
      .videoLayerInternalIds = ids
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
      case .vfxSource, .clock: row.supportsPlacement = true
      default: row.supportsPlacement = false
      }
      row.isHidden = preferences.videoLayerHidden[id] ?? false
      if !row.hasLocalTextChanges && !row.isEditing {
        row.display(
          preferences.videoLayerTransforms[id] ?? .init(), canvasWidth: 1920, canvasHeight: 1080)
      }
      row.onCommit = { [weak self, weak row] in
        guard let self, let row, row.hasLocalTextChanges, let program,
          self.programID == program,
          self.rows[id] === row,
          self.stateService.workspacePreferences[keyPath: self.target.preferences][program]?
            .videoLayerInternalIds.contains(id) == true
        else { return }
        let (transform, incomplete) = self.parsedTransform(for: row)
        let previous = row.transform
        if transform.translationX.double == previous.translationX.double,
          transform.translationY.double == previous.translationY.double,
          transform.scaleX.double == previous.scaleX.double,
          transform.scaleY.double == previous.scaleY.double
        {
          row.hasLocalTextChanges = incomplete
          return
        }
        self.stateService.workspacePreferences[keyPath: self.target.preferences][
          program, default: .init()
        ]
        .videoLayerTransforms[id] = transform
        row.transform = transform
        row.hasLocalTextChanges = incomplete
      }
      row.onSetHidden = { [weak self, weak row] hidden in
        guard let self, let row, let program, self.programID == program,
          self.rows[id] === row,
          self.stateService.workspacePreferences[keyPath: self.target.preferences][program]?
            .videoLayerInternalIds.contains(id) == true
        else { return }
        self.stateService.workspacePreferences[keyPath: self.target.preferences][
          program, default: .init()
        ]
        .videoLayerHidden[id] = hidden
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
      previous.translationX, previous.translationY,
      Ldtx_Workspace_V4_Rational32.with {
        $0.set(num: previous.scaleX.num, den: previous.scaleX.den)
      },
      Ldtx_Workspace_V4_Rational32.with {
        $0.set(num: previous.scaleY.num, den: previous.scaleY.den)
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
  @State var editor: VideoLayersEditorState

  init(
    stateService: WorkspaceStateService, appletData: WorkspaceAppletData,
    target: WorkspaceCanvasTarget
  ) {
    _editor = State(
      initialValue: VideoLayersEditorState(
        stateService: stateService, appletData: appletData, target: target))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(editor.layerIDs, id: \.self) { id in
        if let row = editor.rows[id] {
          VideoLayersTableRowContent(
            state: row, canvasWidth: 1920, canvasHeight: 1080,
            dragToken: editor.token(for: id)
          )
          .padding(4)
          .dropDestination(for: String.self) { (values: [String], point: CGPoint) -> Bool in
            editor.move(values, before: id)
          }
          Divider()
        }
      }
      Color.clear.frame(height: 12)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { (values: [String], point: CGPoint) -> Bool in
          editor.move(values, before: nil)
        }
      if let message = editor.failure ?? editor.stateService.outputFailureMessage {
        Text(message).foregroundStyle(.secondary)
      } else if editor.programID == nil {
        Text("No program selected").foregroundStyle(.secondary)
      } else if editor.layerIDs.isEmpty {
        Text("No video layers").foregroundStyle(.secondary)
      }
    }
    .onChange(of: editor.programID, initial: true) { _, _ in
      editor.synchronizeRows()
    }
    .onChange(of: editor.preferences) { _, _ in editor.synchronizeRows() }
    .onChange(of: editor.stateService.workspaceDefinition) { _, _ in editor.synchronizeRows() }
  }

}
