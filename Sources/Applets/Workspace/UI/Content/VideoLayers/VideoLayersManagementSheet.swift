// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import AppKit
import LDTXWorkspaceAppletInterface

final class VideoLayersManagementSheet: NSWindowController {
  private(set) var draft: VideoLayersManagementDraft
  private var currentIDs: [UInt64]
  private var options: [WorkspaceSelectionOption<UInt64>]
  private var active = false
  private var invalidated = false
  let applyButton = ContentActionButton("Apply")
  let errorLabel = NSTextField(labelWithString: "")
  private(set) var checkboxes: [UInt64: ContentActionButton] = [:]
  var commit: ([UInt64], [UInt64], [WorkspaceSelectionOption<UInt64>]) throws -> Void = { _, _, _ in
  }
  var onClose: () -> Void = {}

  init(ids: [UInt64], options: [WorkspaceSelectionOption<UInt64>]) {
    draft = .init(ids: ids, options: options)
    currentIDs = ids
    self.options = options
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    super.init(window: window)
    window.title = "Manage Video Layers"
    let candidates =
      ids.map { id in
        options.first { $0.id == id } ?? .init(id: id, name: "Missing Video Layer")
      } + options.filter { !ids.contains($0.id) }
    let rows = candidates.map { option -> NSView in
      let button = ContentActionButton(option.name, checkbox: true)
      button.state = ids.contains(option.id) ? .on : .off
      button.invoke = { [weak self, weak button] in
        guard let self, let button else { return }
        if button.state == .on { draft.add(option.id) } else { draft.remove(option.id) }
        errorLabel.stringValue = ""
        refreshControls()
      }
      checkboxes[option.id] = button
      return button
    }
    let scroll = contentScroll(
      contentStack(
        rows.isEmpty ? [NSTextField(labelWithString: "No available video layers")] : rows))
    let cancel = ContentActionButton("Cancel") { [weak self] in self?.onClose() }
    cancel.keyEquivalent = "\u{1b}"
    applyButton.keyEquivalent = "\r"
    applyButton.invoke = { [weak self] in self?.apply() }
    errorLabel.textColor = .systemRed
    let stack = contentStack([
      scroll, errorLabel, contentStack([cancel, applyButton], vertical: false),
    ])
    pinContent(stack, in: window.contentView!)
    scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    scroll.heightAnchor.constraint(equalToConstant: 280).isActive = true
    refreshControls()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func update(ids: [UInt64], options: [WorkspaceSelectionOption<UInt64>], active: Bool) {
    invalidated = invalidated || ids != draft.originalIDs || options != draft.originalOptions
    currentIDs = ids
    self.options = options
    self.active = active
    refreshControls()
  }
  private func refreshControls() {
    applyButton.isEnabled =
      !invalidated && draft.canApply(currentIDs: currentIDs, options: options, active: active)
    for button in checkboxes.values { button.isEnabled = !invalidated && !active }
    if invalidated { errorLabel.stringValue = "Video layers changed. Reopen this sheet." }
  }
  func apply() {
    guard applyButton.isEnabled else { return }
    do {
      try draft.apply(currentIDs: currentIDs, options: options, active: active, commit: commit)
      onClose()
    } catch { errorLabel.stringValue = error.localizedDescription }
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

extension VideoLayersManagementSheet {
  static func options(in definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4)
    -> [WorkspaceSelectionOption<UInt64>]
  {
    let components = definition.videoComponents.compactMap {
      component -> WorkspaceSelectionOption<UInt64>? in
      guard let id = try? WorkspaceV4IntegrityValidator.videoComponentID(component),
        let name = component.displayName
      else { return nil }
      return .init(id: id, name: name)
    }
    return components
  }
}
