// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXVariableStore

/// TextKit 2 editing with standard image attachments, without embedded attachment views.
@MainActor
final class MacroTextView: NSTextView, NSTextViewDelegate {
  static let variableAttribute = NSAttributedString.Key("tokyo.kaito.ldtx.variable-reference")
  static let pasteboardType = NSPasteboard.PasteboardType("tokyo.kaito.ldtx.variable-macro.xml.v1")
  var onDocumentChange: (VariableMacroDocument) -> Void = { _ in }
  var onSelectionChange: (VariableKey?, Bool) -> Void = { _, _ in }
  private(set) var keys: [VariableKey] = []
  private(set) var names: [VariableKey: String] = [:]
  private var adopting = false
  private var baseAttributes: [NSAttributedString.Key: Any] {
    [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.textColor]
  }
  var document: VariableMacroDocument { Self.document(from: attributedString()) }

  func configure(
    document: VariableMacroDocument, keys: [VariableKey], names: [VariableKey: String],
    isEnabled: Bool
  ) {
    adopting = true
    defer { adopting = false }
    let labelsChanged = self.names != names
    self.keys = keys
    self.names = names
    delegate = self
    isRichText = true
    importsGraphics = false
    // Workspace records the bound document; do not also register native text edits.
    allowsUndo = false
    isEditable = isEnabled
    isSelectable = true
    isAutomaticQuoteSubstitutionEnabled = false
    isAutomaticDashSubstitutionEnabled = false
    isAutomaticTextReplacementEnabled = false
    isAutomaticLinkDetectionEnabled = false
    setAccessibilityLabel("Dynamic Text macro editor")
    setAccessibilityHelp(
      "Variables are single items. Click a variable to choose a replacement, or select it and use Insert Variable."
    )
    guard !hasMarkedText() else { return }
    if self.document != document {
      let selection = selectedRange()
      textStorage?.setAttributedString(attributed(document))
      setSelectedRange(NSRange(location: min(selection.location, string.utf16.count), length: 0))
      Task { @MainActor [weak self] in self?.reportSelection() }
    } else if labelsChanged {
      refreshLabels()
    }
    typingAttributes = baseAttributes
  }

  func attributed(_ document: VariableMacroDocument) -> NSAttributedString {
    let result = NSMutableAttributedString(string: "")
    for segment in document.segments {
      switch segment {
      case .text(let text):
        result.append(NSAttributedString(string: text, attributes: baseAttributes))
      case .variable(let key): result.append(variableText(key))
      }
    }
    return result
  }

  static func document(from text: NSAttributedString) -> VariableMacroDocument {
    var segments: [VariableMacroSegment] = []
    text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) {
      attributes, range, _ in
      if attributes[.attachment] is NSTextAttachment,
        let path = attributes[variableAttribute] as? String,
        let key = try? VariableKey(path: path), key.visionID > 0
      {
        segments.append(.variable(key))
      } else {
        segments.append(.text(text.attributedSubstring(from: range).string))
      }
    }
    return VariableMacroDocument(segments: segments)
  }

  private func variableText(_ key: VariableKey) -> NSAttributedString {
    let label = names[key] ?? "Missing: \(key.path)"
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 12, weight: .medium),
      .foregroundColor: NSColor.controlAccentColor,
    ]
    let width = min(240, max(48, (label as NSString).size(withAttributes: attributes).width + 24))
    let image = NSImage(size: NSSize(width: width, height: 24))
    image.accessibilityDescription = "Variable: \(label)"
    image.lockFocus()
    NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: 24), xRadius: 7, yRadius: 7)
      .fill()
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingMiddle
    var labelAttributes = attributes
    labelAttributes[.paragraphStyle] = paragraph
    (label as NSString).draw(
      in: NSRect(x: 10, y: 4, width: width - 20, height: 17), withAttributes: labelAttributes)
    image.unlockFocus()
    let attachment = NSTextAttachment()
    attachment.image = image
    attachment.bounds = CGRect(x: 0, y: -6, width: width, height: 24)
    attachment.allowsTextAttachmentView = false
    let value = NSMutableAttributedString(attachment: attachment)
    value.addAttributes(
      baseAttributes.merging([Self.variableAttribute: key.path]) { _, new in new },
      range: NSRange(location: 0, length: 1))
    return value
  }

  private func refreshLabels() {
    guard let storage = textStorage else { return }
    var replacements: [(NSRange, VariableKey)] = []
    storage.enumerateAttribute(
      Self.variableAttribute, in: NSRange(location: 0, length: storage.length)
    ) { value, range, _ in
      if let path = value as? String, let key = try? VariableKey(path: path) {
        replacements.append((range, key))
      }
    }
    storage.beginEditing()
    for (range, key) in replacements {
      if let attachment = variableText(key).attribute(.attachment, at: 0, effectiveRange: nil) {
        storage.addAttribute(.attachment, value: attachment, range: range)
      }
    }
    storage.endEditing()
  }

  func insertVariable(_ key: VariableKey) {
    guard isEditable, !hasMarkedText(), keys.contains(key) else { return }
    window?.makeFirstResponder(self)
    insertText(variableText(key), replacementRange: selectedRange())
    typingAttributes = baseAttributes
  }

  override func didChangeText() {
    super.didChangeText()
    reportChange()
  }
  private func reportChange() {
    guard !adopting else { return }
    reportSelection()
    guard !hasMarkedText() else { return }
    onDocumentChange(document)
  }
  func textViewDidChangeSelection(_ notification: Notification) {
    guard !adopting else { return }
    if !hasMarkedText() { typingAttributes = baseAttributes }
    reportSelection()
  }
  private func reportSelection() {
    let range = selectedRange()
    let path =
      range.length == 1 && range.location < string.utf16.count
      ? textStorage?.attribute(Self.variableAttribute, at: range.location, effectiveRange: nil)
        as? String : nil
    onSelectionChange(path.flatMap { try? VariableKey(path: $0) }, hasMarkedText())
  }
  override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    reportSelection()
  }
  override func unmarkText() {
    super.unmarkText()
    reportChange()
  }

  override func mouseDown(with event: NSEvent) {
    guard isEditable, !hasMarkedText() else {
      super.mouseDown(with: event)
      return
    }
    let point = convert(event.locationInWindow, from: nil)
    let insertion = characterIndexForInsertion(at: point)
    for index in [insertion, insertion - 1] where index >= 0 && index < string.utf16.count {
      guard textStorage?.attribute(Self.variableAttribute, at: index, effectiveRange: nil) != nil
      else { continue }
      let range = NSRange(location: index, length: 1)
      let rect = firstRect(forCharacterRange: range, actualRange: nil)
      guard let window, rect.contains(window.convertPoint(toScreen: event.locationInWindow)) else {
        continue
      }
      window.makeFirstResponder(self)
      setSelectedRange(range)
      showVariableMenu(at: point)
      return
    }
    super.mouseDown(with: event)
  }
  private func showVariableMenu(at point: NSPoint) {
    let menu = NSMenu(title: "Replace Variable")
    for key in keys {
      let item = NSMenuItem(
        title: names[key] ?? key.path, action: #selector(chooseVariable(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = key.path
      menu.addItem(item)
    }
    menu.addItem(.separator())
    let remove = NSMenuItem(
      title: "Remove Variable", action: #selector(removeVariable(_:)), keyEquivalent: "")
    remove.target = self
    menu.addItem(remove)
    menu.popUp(positioning: nil, at: point, in: self)
  }
  @objc private func chooseVariable(_ sender: NSMenuItem) {
    guard let path = sender.representedObject as? String, let key = try? VariableKey(path: path)
    else { return }
    insertVariable(key)
  }
  @objc private func removeVariable(_ sender: NSMenuItem) {
    guard isEditable, !hasMarkedText(), selectedRange().length == 1 else { return }
    insertText("", replacementRange: selectedRange())
  }

  func writeSelection(to pasteboard: NSPasteboard) {
    guard !hasMarkedText() else { return }
    let document = Self.document(
      from: attributedString().attributedSubstring(from: selectedRange()))
    pasteboard.clearContents()
    pasteboard.setString(document.xml, forType: Self.pasteboardType)
    pasteboard.setString(document.plainText, forType: .string)
  }
  func paste(from pasteboard: NSPasteboard) {
    guard isEditable, !hasMarkedText() else { return }
    if let xml = pasteboard.string(forType: Self.pasteboardType),
      let document = try? VariableMacroDocument(xml: xml)
    {
      insertText(attributed(document), replacementRange: selectedRange())
    } else if let text = pasteboard.string(forType: .string) {
      insertText(
        NSAttributedString(string: text, attributes: baseAttributes),
        replacementRange: selectedRange())
    }
    typingAttributes = baseAttributes
  }
  override func copy(_ sender: Any?) { writeSelection(to: .general) }
  override func cut(_ sender: Any?) {
    guard isEditable, !hasMarkedText() else { return }
    copy(sender)
    insertText("", replacementRange: selectedRange())
  }
  override func paste(_ sender: Any?) { paste(from: .general) }
}
