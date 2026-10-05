// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import AppKit
import LDTXWorkspaceAppletInterface

final class VideoLayersEditor: NSViewController {
  let container = VideoLayersTableContainer()
  let manageButton = NSButton(title: "Manage Video Layers…", target: nil, action: nil)
  let errorLabel = NSTextField(labelWithString: "")
  let outputErrorLabel = NSTextField(wrappingLabelWithString: "")
  let emptyLabel = NSTextField(labelWithString: "No program selected")
  private(set) var manager: VideoLayersManagementSheet?
  private var programID: UInt64?
  private var input: VideoLayersTableInput?
  private var isOutputActive = false
  var commitMembership: ([UInt64], [UInt64], [WorkspaceSelectionOption<UInt64>]) throws -> Void = {
    _, _, _ in
  }

  override func loadView() {
    let stack = NSStackView(views: [
      manageButton, emptyLabel, container, errorLabel, outputErrorLabel,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    view = NSView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
      stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
      container.widthAnchor.constraint(equalTo: stack.widthAnchor),
      container.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
    ])
    errorLabel.textColor = .systemRed
    outputErrorLabel.textColor = .systemRed
    manageButton.target = self
    manageButton.action = #selector(openManager)
  }

  func update(programID: UInt64?, input: VideoLayersTableInput, active: Bool) {
    _ = view
    if self.programID != programID {
      closeManager()
      // Discard the old Program's field editor before replacing its rows.
      container.table.rows.values.forEach { $0.discardEditing() }
      view.window?.makeFirstResponder(nil)
      container.table.update(
        VideoLayersTableInput(
          layerIDs: [], programPreferences: .init(), definition: .init(),
          canvasWidth: input.canvasWidth, canvasHeight: input.canvasHeight))
      errorLabel.stringValue = ""
    }
    self.programID = programID
    self.input = input
    isOutputActive = active
    manageButton.isEnabled = programID != nil && !active
    emptyLabel.stringValue = programID == nil ? "No program selected" : "No video layers"
    emptyLabel.isHidden = programID != nil && !input.layerIDs.isEmpty
    container.table.update(input)
    if active { closeManager() }
    manager?.update(
      ids: input.layerIDs, options: Self.options(in: input.definition), active: active)
  }

  @objc func openManager() {
    guard programID != nil, !isOutputActive, manager == nil, let input, let window = view.window
    else { return }
    let sheet = VideoLayersManagementSheet(
      ids: input.layerIDs, options: Self.options(in: input.definition))
    sheet.commit = { [weak self] ids, baseline, candidates in
      guard let self else { throw WorkspaceSelectionError(message: "Workspace is unavailable.") }
      try commitMembership(ids, baseline, candidates)
    }
    sheet.onClose = { [weak self] in self?.closeManager() }
    manager = sheet
    window.beginSheet(sheet.window!)
  }

  func closeManager() {
    guard let manager else { return }
    if let window = manager.window, let parent = window.sheetParent { parent.endSheet(window) }
    manager.window?.orderOut(nil)
    self.manager = nil
  }

  static func options(in definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4)
    -> [WorkspaceSelectionOption<UInt64>]
  {
    let inputs = definition.inputDevices.compactMap { input -> WorkspaceSelectionOption<UInt64>? in
      guard case .videoDevice(let device)? = input.definition else { return nil }
      return .init(id: device.internalID, name: device.displayName)
    }
    let components = definition.videoComponents.compactMap {
      component -> WorkspaceSelectionOption<UInt64>? in
      switch component.definition {
      case .vfxSource(let v): return .init(id: v.internalID, name: v.displayName)
      case .solidColorFill(let v): return .init(id: v.internalID, name: v.displayName)
      case .linearGradientFill(let v): return .init(id: v.internalID, name: v.displayName)
      case .radialGradientFill(let v): return .init(id: v.internalID, name: v.displayName)
      case .conicGradientFill(let v): return .init(id: v.internalID, name: v.displayName)
      case .clock(let v): return .init(id: v.internalID, name: v.displayName)
      case .testPattern(let v): return .init(id: v.internalID, name: v.displayName)
      case nil: return nil
      }
    }
    return inputs + components
  }
}

struct VideoLayersManagementDraft {
  let originalIDs: [UInt64]
  let originalOptions: [WorkspaceSelectionOption<UInt64>]
  var ids: [UInt64]

  init(ids: [UInt64], options: [WorkspaceSelectionOption<UInt64>]) {
    originalIDs = ids
    originalOptions = options
    self.ids = ids
  }

  mutating func add(_ id: UInt64) {
    guard !ids.contains(id),
      originalIDs.contains(id) || originalOptions.contains(where: { $0.id == id })
    else { return }
    ids.append(id)
    // Restoring a checkbox must not reorder an existing layer.
    ids = originalIDs.filter { ids.contains($0) } + ids.filter { !originalIDs.contains($0) }
  }

  mutating func remove(_ id: UInt64) { ids.removeAll { $0 == id } }

  func canApply(currentIDs: [UInt64], options: [WorkspaceSelectionOption<UInt64>], active: Bool)
    -> Bool
  {
    !active && ids != originalIDs && currentIDs == originalIDs && options == originalOptions
  }
  func apply(
    currentIDs: [UInt64], options: [WorkspaceSelectionOption<UInt64>], active: Bool,
    commit: ([UInt64], [UInt64], [WorkspaceSelectionOption<UInt64>]) throws -> Void
  ) throws {
    guard canApply(currentIDs: currentIDs, options: options, active: active) else {
      throw WorkspaceSelectionError(message: "Video layers changed or cannot be managed now.")
    }
    try commit(ids, originalIDs, originalOptions)
  }

}
