// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletInterface

final class VideoLayerRowView: NSTableCellView, NSTextFieldDelegate {
  let internalID: UInt64
  let handle = NSImageView()
  let nameLabel = NSTextField(labelWithString: "")
  let hideButton = NSButton(checkboxWithTitle: "Hide", target: nil, action: nil)
  let upButton = NSButton(title: "↑", target: nil, action: nil)
  let downButton = NSButton(title: "↓", target: nil, action: nil)
  let removeButton = NSButton(title: "−", target: nil, action: nil)
  let fields = (0..<4).map { _ in VideoLayerTextField(string: "") }
  let errorLabel = NSTextField(labelWithString: "")
  private(set) var hasUnconfirmedChanges = false
  private var isEditing = false
  private var width: Double = 1920
  private var height: Double = 1080
  private var onAction: (UInt64, VideoLayerAction) -> Void = { _, _ in }
  private var onCommitTransform: (UInt64, Ldtx_Workspace_V4_BasicTransform) throws -> Void = {
    _, _ in
  }

  init(internalID: UInt64) {
    self.internalID = internalID
    super.init(frame: .zero)
    textField = nameLabel
    imageView = handle
    handle.image = NSImage(
      systemSymbolName: "line.3.horizontal", accessibilityDescription: "Reorder layer")
    handle.setAccessibilityLabel("Reorder layer")
    let top = NSStackView(views: [
      handle, nameLabel, hideButton, upButton, downButton, removeButton,
    ])
    top.orientation = .horizontal
    top.alignment = .centerY
    top.spacing = 8
    top.distribution = .fill
    nameLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    nameLabel.lineBreakMode = .byTruncatingTail
    let numbers = NSStackView()
    numbers.orientation = .horizontal
    numbers.alignment = .centerY
    numbers.spacing = 8
    for (index, title) in ["Pos X", "Pos Y", "Scale X", "Scale Y"].enumerated() {
      let field = fields[index]
      field.delegate = self
      field.isAutomaticTextCompletionEnabled = false
      field.allowsWritingTools = false
      field.allowsCharacterPickerTouchBarItem = false
      field.setAccessibilityLabel(title)
      field.setContentHuggingPriority(.defaultLow, for: .horizontal)
      numbers.addArrangedSubview(NSTextField(labelWithString: title))
      numbers.addArrangedSubview(field)
      if index > 0 { field.widthAnchor.constraint(equalTo: fields[0].widthAnchor).isActive = true }
    }
    let stack = NSStackView(views: [top, numbers, errorLabel])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      top.widthAnchor.constraint(equalTo: stack.widthAnchor),
      numbers.widthAnchor.constraint(equalTo: stack.widthAnchor),
      handle.widthAnchor.constraint(equalToConstant: 20),
      handle.heightAnchor.constraint(equalToConstant: 20),
    ])
    for button in [hideButton, upButton, downButton, removeButton] {
      button.setContentHuggingPriority(.required, for: .horizontal)
      button.target = self
      button.action = #selector(performAction(_:))
      if button !== hideButton { button.bezelStyle = .rounded }
    }
    upButton.setAccessibilityLabel("Move layer up")
    downButton.setAccessibilityLabel("Move layer down")
    removeButton.setAccessibilityLabel("Remove layer")
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(
    name: String, transform: Ldtx_Workspace_V4_BasicTransform,
    width: Double, height: Double, hidden: Bool, canMoveUp: Bool, canMoveDown: Bool,
    canRemove: Bool, onAction: @escaping (UInt64, VideoLayerAction) -> Void,
    onCommitTransform: @escaping (UInt64, Ldtx_Workspace_V4_BasicTransform) throws -> Void
  ) {
    nameLabel.stringValue = name
    self.width = width
    self.height = height
    self.onAction = onAction
    self.onCommitTransform = onCommitTransform
    hideButton.state = hidden ? .on : .off
    upButton.isEnabled = canMoveUp
    downButton.isEnabled = canMoveDown
    removeButton.isEnabled = canRemove
    if !hasUnconfirmedChanges && !isEditing { display(transform) }
  }

  private func display(_ transform: Ldtx_Workspace_V4_BasicTransform) {
    let strings = [
      String(Double(transform.translationX) * width),
      String(Double(transform.translationY) * height), String(transform.scaleX),
      String(transform.scaleY),
    ]
    for (field, string) in zip(fields, strings) { field.stringValue = string }
  }

  @objc private func performAction(_ sender: NSButton) {
    if sender === hideButton { onAction(internalID, sender.state == .on ? .hide : .show) }
    if sender === upButton { onAction(internalID, .moveUp) }
    if sender === downButton { onAction(internalID, .moveDown) }
    if sender === removeButton { onAction(internalID, .remove) }
  }

  func controlTextDidBeginEditing(_ notification: Notification) {
    isEditing = true
  }

  func controlTextDidChange(_ notification: Notification) { hasUnconfirmedChanges = true }

  func controlTextDidEndEditing(_ notification: Notification) {
    isEditing = false
    commit()
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
    -> Bool
  {
    guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
    commit()
    return true
  }

  func commit() {
    guard hasUnconfirmedChanges else { return }
    let values = fields.compactMap { Double($0.stringValue) }
    guard values.count == 4, values.allSatisfy(\.isFinite) else {
      errorLabel.stringValue = "Invalid number."
      return
    }
    let numbers = [
      Float(values[0] / width), Float(values[1] / height), Float(values[2]), Float(values[3]),
    ]
    guard numbers.allSatisfy(\.isFinite) else {
      errorLabel.stringValue = "Invalid number."
      return
    }
    var transform = Ldtx_Workspace_V4_BasicTransform()
    transform.translationX = numbers[0]
    transform.translationY = numbers[1]
    transform.scaleX = numbers[2]
    transform.scaleY = numbers[3]
    do {
      try onCommitTransform(internalID, transform)
      hasUnconfirmedChanges = false
      errorLabel.stringValue = ""
      display(transform)
    } catch {
      errorLabel.stringValue = error.localizedDescription
    }
  }
}

// AppKit applies field-editor defaults after the begin-editing notification.
// Configure these options after the standard responder setup has completed.
final class VideoLayerTextField: NSTextField {
  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted, let editor = currentEditor() as? NSTextView {
      editor.isAutomaticSpellingCorrectionEnabled = false
      editor.isContinuousSpellCheckingEnabled = false
      editor.isGrammarCheckingEnabled = false
      editor.isAutomaticTextReplacementEnabled = false
      editor.isAutomaticQuoteSubstitutionEnabled = false
      editor.isAutomaticDashSubstitutionEnabled = false
      editor.isAutomaticDataDetectionEnabled = false
    }
    return accepted
  }
}
