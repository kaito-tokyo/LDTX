// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import AppKit

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
