// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletInterface

final class VideoLayerRowView: NSTableCellView, NSTextFieldDelegate {
  let internalID: UInt64
  let handle = NSImageView()
  let nameLabel = NSTextField(labelWithString: "")
  let hideButton = NSButton(checkboxWithTitle: "Hide", target: nil, action: nil)
  let fields = (0..<4).map { _ in NSTextField(string: "") }
  let errorLabel = NSTextField(labelWithString: "")
  private(set) var hasUnconfirmedChanges = false
  private var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
  private var layerName: String {
    for input in definition.inputDevices {
      if case .videoDevice(let device)? = input.definition, device.internalID == internalID {
        return device.displayName
      }
    }
    for component in definition.videoComponents {
      let id: UInt64?
      let name: String
      switch component.definition {
      case .vfxSource(let value): (id, name) = (value.internalID, value.displayName)
      case .solidColorFill(let value): (id, name) = (value.internalID, value.displayName)
      case .linearGradientFill(let value): (id, name) = (value.internalID, value.displayName)
      case .radialGradientFill(let value): (id, name) = (value.internalID, value.displayName)
      case .conicGradientFill(let value): (id, name) = (value.internalID, value.displayName)
      case .clock(let value): (id, name) = (value.internalID, value.displayName)
      case .testPattern(let value): (id, name) = (value.internalID, value.displayName)
      case nil: (id, name) = (nil, "Invalid Video Component")
      }
      if id == internalID { return name }
    }
    return "Missing Video Layer"
  }
  private var programPreferences = Ldtx_Workspace_V4_ProgramPreferences()
  private var transform: Ldtx_Workspace_V4_BasicTransform {
    programPreferences.videoLayerTransforms[internalID] ?? .init()
  }
  private var isLayerHidden: Bool { programPreferences.videoLayerHidden[internalID] ?? false }
  private var isEditing = false
  private var canvasWidth: Double = 1920
  private var canvasHeight: Double = 1080
  private var preferences: () throws -> Ldtx_Workspace_V4_ProgramPreferences = { .init() }
  private var onCommitPreferences: (Ldtx_Workspace_V4_ProgramPreferences) throws -> Void = { _ in }
  private var onError: (Error) -> Void = { _ in }

  init(internalID: UInt64) {
    self.internalID = internalID
    super.init(frame: .zero)
    textField = nameLabel
    imageView = handle
    handle.image = NSImage(
      systemSymbolName: "line.3.horizontal", accessibilityDescription: "Reorder layer")
    handle.setAccessibilityLabel("Reorder layer")
    let top = NSStackView(views: [
      handle, nameLabel, hideButton,
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
    hideButton.setContentHuggingPriority(.required, for: .horizontal)
    hideButton.target = self
    hideButton.action = #selector(performAction(_:))
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    programPreferences: Ldtx_Workspace_V4_ProgramPreferences,
    canvasWidth: Double, canvasHeight: Double,
    preferences: @escaping () throws -> Ldtx_Workspace_V4_ProgramPreferences,
    onCommitPreferences: @escaping (Ldtx_Workspace_V4_ProgramPreferences) throws -> Void,
    onError: @escaping (Error) -> Void
  ) {
    self.definition = definition
    self.programPreferences = programPreferences
    nameLabel.stringValue = layerName
    self.canvasWidth = canvasWidth
    self.canvasHeight = canvasHeight
    self.preferences = preferences
    self.onCommitPreferences = onCommitPreferences
    self.onError = onError
    hideButton.state = isLayerHidden ? .on : .off
    if !hasUnconfirmedChanges && !isEditing { display(transform) }
  }

  private func display(_ transform: Ldtx_Workspace_V4_BasicTransform) {
    let strings = [
      String(Double(transform.translationX) * canvasWidth),
      String(Double(transform.translationY) * canvasHeight), String(transform.scaleX),
      String(transform.scaleY),
    ]
    for (field, string) in zip(fields, strings) { field.stringValue = string }
  }

  @objc private func performAction(_ sender: NSButton) {
    do {
      var updated = try preferences()
      updated.videoLayerHidden[internalID] = sender.state == .on
      try onCommitPreferences(updated)
    } catch {
      hideButton.state = isLayerHidden ? .on : .off
      onError(error)
    }
  }

  func controlTextDidBeginEditing(_ notification: Notification) {
    isEditing = true
    if let field = notification.object as? NSTextField,
      let editor = field.currentEditor() as? NSTextView
    {
      editor.isAutomaticSpellingCorrectionEnabled = false
      editor.isContinuousSpellCheckingEnabled = false
      editor.isGrammarCheckingEnabled = false
      editor.isAutomaticQuoteSubstitutionEnabled = false
      editor.isAutomaticDashSubstitutionEnabled = false
      editor.isAutomaticDataDetectionEnabled = false
    }
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

  func discardEditing() {
    hasUnconfirmedChanges = false
    isEditing = false
  }

  func commit() {
    guard hasUnconfirmedChanges else { return }
    let values = fields.compactMap { Double($0.stringValue) }
    guard values.count == 4, values.allSatisfy(\.isFinite) else {
      errorLabel.stringValue = "Invalid number."
      return
    }
    let numbers = [
      Float(values[0] / canvasWidth), Float(values[1] / canvasHeight), Float(values[2]),
      Float(values[3]),
    ]
    guard numbers.allSatisfy(\.isFinite) else {
      errorLabel.stringValue = "Invalid number."
      return
    }
    do {
      var updated = try preferences()
      var transform = updated.videoLayerTransforms[internalID] ?? .init()
      transform.translationX = numbers[0]
      transform.translationY = numbers[1]
      transform.scaleX = numbers[2]
      transform.scaleY = numbers[3]
      updated.videoLayerTransforms[internalID] = transform
      try onCommitPreferences(updated)
      hasUnconfirmedChanges = false
      errorLabel.stringValue = ""
      display(transform)
    } catch {
      errorLabel.stringValue = error.localizedDescription
    }
  }
}
