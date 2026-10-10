import AppKit
import LDTXBackgroundSegmentation
// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import LDTXProtos
import LDTXWorkspaceAppletModel
import SwiftUI

final class VideoLayersEditor: NSViewController, VideoLayersTableRowDelegate {
  let table = VideoLayersTableView()

  private let status = NSTextField(wrappingLabelWithString: "")
  private let appletData: WorkspaceAppletData
  private let storeService: WorkspaceStoreService
  private let editingState: WorkspaceEditingState
  private let target: WorkspaceCanvasTarget
  private var displayedProgramID: Int64?
  private var selectedProgram: Ldtx_Workspace_V4_ProgramDefinition? {
    appletData.selectedProgram(
      in: storeService.workspaceDefinition, for: storeService.localStateURL)
  }

  init(
    storeService: WorkspaceStoreService, appletData: WorkspaceAppletData,
    editingState: WorkspaceEditingState,
    target: WorkspaceCanvasTarget
  ) {
    self.appletData = appletData
    self.storeService = storeService
    self.editingState = editingState
    self.target = target
    super.init(nibName: nil, bundle: nil)
    editingState.registerContentEditValidator(
      hasChanges: { [weak self] in
        self?.table.rows.values.contains { $0.state.hasUnconfirmedChanges } ?? false
      },
      submit: { [weak self] in
        guard let self else { return }
        for row in table.rows.values where row.state.hasUnconfirmedChanges {
          try commit(row)
        }
      }
    ) { [weak self] in
      guard let self else { return }
      for row in table.rows.values where row.state.hasUnconfirmedChanges {
        _ = try validatedTransform(for: row)
      }
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var onCommitTransform:
    (Int64, Ldtx_Workspace_V4_BasicTransform) throws -> Ldtx_Workspace_V4_BasicTransform = {
      _, value in value
    }
  private var onSetHidden: (Int64, Bool) throws -> Void = { _, _ in }
  private var onError: (Error) -> Void = { _ in }

  private func internalID(for row: VideoLayersTableRow) throws -> Int64 {
    guard let id = table.rows.first(where: { $0.value === row })?.key else {
      throw WorkspaceSelectionError(message: "Video layer is no longer available.")
    }
    return id
  }

  func videoLayersTableRowDidRequestCommit(_ row: VideoLayersTableRow) {
    do { try commit(row) } catch { onError(error) }
  }

  private func commit(_ row: VideoLayersTableRow) throws {
    guard row.state.hasUnconfirmedChanges else { return }
    let id = try internalID(for: row)
    let transform = try validatedTransform(for: row)
    let saved = try onCommitTransform(id, transform)
    row.state.display(
      saved, canvasWidth: row.rootView.canvasWidth, canvasHeight: row.rootView.canvasHeight)
    editingState.refreshUnconfirmedChanges()
  }

  private func validatedTransform(for row: VideoLayersTableRow) throws
    -> Ldtx_Workspace_V4_BasicTransform
  {
    let labels = ["Pos X", "Pos Y", "Scale X", "Scale Y"]
    let values = try row.state.strings.enumerated().map { index, text in
      do {
        if index < 2 {
          let size: UInt32 = index == 0 ? 1920 : 1080
          guard let pixels = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            pixels >= 0, UInt32(pixels) <= size
          else {
            throw WorkspaceSelectionError(
              message: "Enter an integer pixel position from 0 to \(size).")
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
        throw WorkspaceSelectionError(
          message:
            "Invalid number (\(labels[index])): \(error.localizedDescription)")
      }
    }
    var transform = Ldtx_Workspace_V4_BasicTransform()
    transform.translationX = values[0]
    transform.translationY = values[1]
    transform.scaleX = .init(value: values[2])
    transform.scaleY = .init(value: values[3])
    try WorkspaceV4IntegrityValidator.validateTransform(transform)
    return transform
  }

  func videoLayersTableRow(_ row: VideoLayersTableRow, setHidden hidden: Bool) {
    guard let id = try? internalID(for: row) else { return }
    do {
      try onSetHidden(id, hidden)
      row.state.isHidden = hidden
    } catch {
      onError(error)
    }
  }

  func update(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    programPreferences: Ldtx_Workspace_V4_ProgramPreferences,
    layerIDs: [Int64], canvasWidth: Double, canvasHeight: Double,
    onCommitTransform:
      @escaping (Int64, Ldtx_Workspace_V4_BasicTransform) throws ->
      Ldtx_Workspace_V4_BasicTransform = { _, value in value },
    onSetHidden: @escaping (Int64, Bool) throws -> Void = { _, _ in },
    onCommitLayerOrder: @escaping ([Int64]) throws -> Void = { _ in },
    onError: @escaping (Error) -> Void = { _ in }
  ) {
    _ = view
    self.onCommitTransform = onCommitTransform
    self.onSetHidden = onSetHidden
    self.onError = onError
    var names: [Int64: String] = [:]
    var placementSupport: [Int64: Bool] = [:]
    for component in definition.videoComponents {
      if let id = component.internalID, names[id] == nil {
        names[id] = component.displayName
        switch component.videoComponent {
        case .vfxSource, .clock: placementSupport[id] = true
        default: placementSupport[id] = false
        }
      }
    }
    var rows: [Int64: VideoLayersTableRow] = [:]
    for id in layerIDs {
      let row: VideoLayersTableRow
      if let existing = table.rows[id],
        existing.rootView.canvasWidth == canvasWidth, existing.rootView.canvasHeight == canvasHeight
      {
        row = existing
      } else {
        row = VideoLayersTableRow(
          rootView: VideoLayersTableRowContent(
            state: VideoLayersTableRowState(),
            canvasWidth: canvasWidth, canvasHeight: canvasHeight))
        row.state.onCommit = { [weak row] in
          guard let row else { return }
          row.delegate?.videoLayersTableRowDidRequestCommit(row)
        }
        row.state.onSetHidden = { [weak row] value in
          guard let row else { return }
          row.delegate?.videoLayersTableRow(row, setHidden: value)
        }
      }
      row.state.onEditsChanged = { [weak editingState] in
        editingState?.refreshUnconfirmedChanges()
      }
      row.delegate = self
      row.state.name = names[id] ?? "Missing Video Layer"
      row.state.supportsPlacement = placementSupport[id] ?? false
      row.state.isHidden = programPreferences.videoLayerHidden[id] ?? false
      if !row.state.hasUnconfirmedChanges && !row.state.isEditing {
        row.state.display(
          programPreferences.videoLayerTransforms[id] ?? .init(),
          canvasWidth: canvasWidth, canvasHeight: canvasHeight)
      }
      rows[id] = row
    }
    table.update(
      layerIDs: layerIDs, rows: rows,
      onCommitLayerOrder: onCommitLayerOrder, onError: onError)
  }

  override func loadView() {
    view = NSView()
    table.setContentHuggingPriority(.required, for: .vertical)
    table.setContentCompressionResistancePriority(.required, for: .vertical)
    let stack = contentStack([table, status])
    pinContent(stack, in: view)
    table.translatesAutoresizingMaskIntoConstraints = false
    table.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    refresh()
  }

  override func viewWillLayout() {
    super.viewWillLayout()
    refresh()
  }

  func commitLayerOrder(_ ids: [Int64], programID: Int64) throws {
    guard storeService.workspaceDefinition.programs.contains(where: { $0.internalID == programID })
    else {
      throw WorkspaceSelectionError(message: "The Program is unavailable.")
    }
    let current =
      storeService.workspacePreferences[keyPath: target.preferences][programID]?
      .videoLayerInternalIds ?? []
    guard current.sorted() == ids.sorted() else {
      throw WorkspaceSelectionError(message: "The video layer order changed.")
    }
    storeService.workspacePreferences[keyPath: target.preferences][programID, default: .init()]
      .videoLayerInternalIds = ids
  }

  func refresh() {
    _ = view
    let id = selectedProgram?.internalID
    if displayedProgramID != id {
      table.removeAllRows()
      displayedProgramID = id
    }
    let preference =
      id.flatMap { storeService.workspacePreferences[keyPath: target.preferences][$0] } ?? .init()
    let layerIDs = preference.videoLayerInternalIds
    update(
      definition: storeService.workspaceDefinition, programPreferences: preference,
      layerIDs: layerIDs,
      canvasWidth: 1920,
      canvasHeight: 1080,
      onCommitTransform: { [weak self] layerID, value in
        guard let self, let id else {
          throw WorkspaceSelectionError(message: "No program selected.")
        }
        guard storeService.workspaceDefinition.programs.contains(where: { $0.internalID == id })
        else {
          throw WorkspaceSelectionError(message: "The Program is unavailable.")
        }
        try WorkspaceV4IntegrityValidator.validateTransform(value)
        var transform =
          storeService.workspacePreferences[keyPath: target.preferences][id]?
          .videoLayerTransforms[layerID] ?? .init()
        transform.translationX = value.translationX
        transform.translationY = value.translationY
        transform.scaleX = value.scaleX
        transform.scaleY = value.scaleY
        storeService.workspacePreferences[keyPath: target.preferences][id, default: .init()]
          .videoLayerTransforms[layerID] = transform
        return transform
      },
      onSetHidden: { [weak self] layerID, value in
        guard let self, let id else {
          throw WorkspaceSelectionError(message: "No program selected.")
        }
        guard storeService.workspaceDefinition.programs.contains(where: { $0.internalID == id })
        else {
          throw WorkspaceSelectionError(message: "The Program is unavailable.")
        }
        storeService.workspacePreferences[keyPath: target.preferences][id, default: .init()]
          .videoLayerHidden[layerID] = value
      },
      onCommitLayerOrder: { [weak self] ids in
        guard let self, let id else {
          throw WorkspaceSelectionError(message: "No program selected.")
        }
        try commitLayerOrder(ids, programID: id)
      },
      onError: { [weak editingState] error in
        editingState?.reportInputValidationError(error)
      })
    status.textColor = .secondaryLabelColor
    status.stringValue =
      storeService.outputFailureMessage
      ?? (id == nil ? "No program selected" : layerIDs.isEmpty ? "No video layers" : "")
    status.isHidden = status.stringValue.isEmpty
  }
}

#if DEBUG

  #Preview("Video Layers Editor", traits: .fixedLayout(width: 720, height: 360)) {
    @Previewable @State var editingState = WorkspaceEditingState()
    let storeService = WorkspaceStoreService(definition: .init(), preferences: .init())
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.videoComponents = ["Camera", "Background", "Portrait Source"].enumerated().map {
      index, name in
      var device = Ldtx_Workspace_V4_VfxSourceComponent()
      device.internalID = Int64(index + 1)
      device.displayName = name
      var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      wrapper.vfxSource = device
      return wrapper
    }
    var programPreferences = Ldtx_Workspace_V4_ProgramPreferences()
    for id: Int64 in [1, 2] {
      var transform = Ldtx_Workspace_V4_BasicTransform()
      transform.scaleX = .with {
        $0.set(num: 1, den: 1)
      }
      transform.scaleY = .with {
        $0.set(num: 1, den: 1)
      }
      programPreferences.videoLayerTransforms[id] = transform
    }
    programPreferences.videoLayerHidden[2] = true
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 100
    programPreferences.videoLayerInternalIds = [1, 2]
    definition.programs = [program]
    storeService.workspaceDefinition = definition
    storeService.workspacePreferences.landscapeProgramPreferences[100] = programPreferences
    let editor = VideoLayersEditor(
      storeService: storeService, appletData: WorkspaceAppletData(), editingState: editingState,
      target: .landscape)
    NSLayoutConstraint.activate([
      editor.view.widthAnchor.constraint(equalToConstant: 720),
      editor.view.heightAnchor.constraint(equalToConstant: 360),
    ])
    return editor
  }

  #Preview("Video Layers Editor — No Program", traits: .fixedLayout(width: 720, height: 360)) {
    let editor = VideoLayersEditor(
      storeService: WorkspaceStoreService(definition: .init(), preferences: .init()),
      appletData: WorkspaceAppletData(), editingState: WorkspaceEditingState(), target: .landscape)
    NSLayoutConstraint.activate([
      editor.view.widthAnchor.constraint(equalToConstant: 720),
      editor.view.heightAnchor.constraint(equalToConstant: 360),
    ])
    return editor
  }
#endif
