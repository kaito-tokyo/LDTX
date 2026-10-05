// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import AppKit
import LDTXWorkspaceAppletInterface
import SwiftUI

final class VideoLayersEditor: NSViewController, VideoLayersTableRowDelegate {
  let scrollView = NSScrollView()
  let table = VideoLayersTableView()
  let manageButton = ContentActionButton("Manage Video Layers…")

  let errorLabel = NSTextField(wrappingLabelWithString: "")
  private var errors: [UInt64: String] = [:] {
    didSet {
      errorLabel.stringValue = table.layerIDs.compactMap { errors[$0] }.joined(separator: "\n")
      errorLabel.isHidden = errorLabel.stringValue.isEmpty
    }
  }

  override init(nibName: NSNib.Name? = nil, bundle: Bundle? = nil) {
    super.init(nibName: nibName, bundle: bundle)
    scrollView.hasVerticalScroller = true
    scrollView.documentView = table
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var onCommitTransform:
    (UInt64, Ldtx_Workspace_V4_BasicTransform) throws -> Ldtx_Workspace_V4_BasicTransform = {
      _, value in value
    }
  private var onSetHidden: (UInt64, Bool) throws -> Void = { _, _ in }
  private var onError: (Error) -> Void = { _ in }

  private func internalID(for row: VideoLayersTableRow) throws -> UInt64 {
    guard let id = table.rows.first(where: { $0.value === row })?.key else {
      throw WorkspaceSelectionError(message: "Video layer is no longer available.")
    }
    return id
  }

  func videoLayersTableRowDidRequestCommit(_ row: VideoLayersTableRow) {
    guard row.state.hasUnconfirmedChanges,
      let id = try? internalID(for: row)
    else { return }
    let values = row.state.strings.map { Double($0) }
    let labels = ["Pos X", "Pos Y", "Scale X", "Scale Y"]
    let invalid = values.indices.filter { values[$0]?.isFinite != true }
    guard invalid.isEmpty else {
      errors[id] =
        "\(row.state.name): Invalid number (\(invalid.map { labels[$0] }.joined(separator: ", ")))."
      return
    }
    let numbers = [
      Float(values[0]! / row.rootView.canvasWidth), Float(values[1]! / row.rootView.canvasHeight),
      Float(values[2]!), Float(values[3]!),
    ]
    let overflow = numbers.indices.filter { !numbers[$0].isFinite }
    guard overflow.isEmpty else {
      errors[id] =
        "\(row.state.name): Invalid number (\(overflow.map { labels[$0] }.joined(separator: ", ")))."
      return
    }
    do {
      var transform = Ldtx_Workspace_V4_BasicTransform()
      transform.translationX = numbers[0]
      transform.translationY = numbers[1]
      transform.scaleX = numbers[2]
      transform.scaleY = numbers[3]
      let saved = try onCommitTransform(id, transform)
      row.state.hasUnconfirmedChanges = false
      row.state.display(
        saved, canvasWidth: row.rootView.canvasWidth, canvasHeight: row.rootView.canvasHeight)
      errors.removeValue(forKey: id)
    } catch {
      errors[id] = "\(row.state.name): \(error.localizedDescription)"
    }
  }

  func videoLayersTableRow(_ row: VideoLayersTableRow, setHidden hidden: Bool) {
    guard let id = try? internalID(for: row) else { return }
    do {
      try onSetHidden(id, hidden)
      row.state.isHidden = hidden
      if !row.state.hasUnconfirmedChanges { errors.removeValue(forKey: id) }
    } catch {
      errors[id] = "\(row.state.name): \(error.localizedDescription)"
      onError(error)
    }
  }

  func update(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    programPreferences: Ldtx_Workspace_V4_ProgramPreferences,
    layerIDs: [UInt64], canvasWidth: Double, canvasHeight: Double,
    onCommitTransform:
      @escaping (UInt64, Ldtx_Workspace_V4_BasicTransform) throws ->
      Ldtx_Workspace_V4_BasicTransform = { _, value in value },
    onSetHidden: @escaping (UInt64, Bool) throws -> Void = { _, _ in },
    onCommitLayerOrder: @escaping ([UInt64]) throws -> Void = { _ in },
    onError: @escaping (Error) -> Void = { _ in }
  ) {
    self.onCommitTransform = onCommitTransform
    self.onSetHidden = onSetHidden
    self.onError = onError
    var names: [UInt64: String] = [:]
    for component in definition.videoComponents {
      if let id = try? WorkspaceV4IntegrityValidator.videoComponentID(component), names[id] == nil {
        names[id] = component.displayName
      }
    }
    errors = errors.filter { layerIDs.contains($0.key) && table.rows[$0.key] != nil }
    var rows: [UInt64: VideoLayersTableRow] = [:]
    for id in layerIDs {
      let row: VideoLayersTableRow
      if let existing = table.rows[id],
        existing.rootView.canvasWidth == canvasWidth, existing.rootView.canvasHeight == canvasHeight
      {
        row = existing
      } else {
        errors.removeValue(forKey: id)
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
      row.delegate = self
      row.state.name = names[id] ?? "Missing Video Layer"
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
    errorLabel.isHidden = errorLabel.stringValue.isEmpty
    let stack = contentStack([manageButton, errorLabel, scrollView])
    pinContent(stack, in: view)
  }
}

#if DEBUG

  #Preview("Video Layers Editor", traits: .fixedLayout(width: 720, height: 360)) {
    let editor = VideoLayersEditor()
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.videoComponents = ["Camera", "Background", "Portrait Source"].enumerated().map {
      index, name in
      var device = Ldtx_Workspace_V4_VfxSourceComponent()
      device.internalID = UInt64(index + 1)
      device.displayName = name
      var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      wrapper.vfxSource = device
      return wrapper
    }
    var programPreferences = Ldtx_Workspace_V4_ProgramPreferences()
    for id: UInt64 in [1, 2] {
      var transform = Ldtx_Workspace_V4_BasicTransform()
      transform.scaleX = 1
      transform.scaleY = 1
      programPreferences.videoLayerTransforms[id] = transform
    }
    programPreferences.videoLayerHidden[2] = true
    editor.update(
      definition: definition, programPreferences: programPreferences, layerIDs: [1, 2],
      canvasWidth: 1920, canvasHeight: 1080,
      onCommitTransform: { id, value in
        programPreferences.videoLayerTransforms[id] = value
        return value
      },
      onSetHidden: { id, value in programPreferences.videoLayerHidden[id] = value })
    NSLayoutConstraint.activate([
      editor.view.widthAnchor.constraint(equalToConstant: 720),
      editor.view.heightAnchor.constraint(equalToConstant: 360),
    ])
    return editor
  }

  #Preview("Video Layers Editor — No Program", traits: .fixedLayout(width: 720, height: 360)) {
    let editor = VideoLayersEditor()
    editor.update(
      definition: .init(), programPreferences: .init(), layerIDs: [],
      canvasWidth: 1920, canvasHeight: 1080)
    NSLayoutConstraint.activate([
      editor.view.widthAnchor.constraint(equalToConstant: 720),
      editor.view.heightAnchor.constraint(equalToConstant: 360),
    ])
    return editor
  }
#endif
