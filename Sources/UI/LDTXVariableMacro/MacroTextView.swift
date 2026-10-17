// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXRichText

/// TextKit 2 editing with standard image attachments, without embedded attachment views.
@MainActor
final class MacroTextView: NSTextView {
  var onDocumentChange: (LDTXRichTextDocument) -> Void = { _ in }
  private(set) var keys: [LDTXVariableReference] = []
  private(set) var names: [LDTXVariableReference: String] = [:]
  var onError: (Error) -> Void = { _ in }
  private var lastPublished: LDTXRichTextDocument?
  private var adopting = false

  convenience init(frame frameRect: NSRect, usingTextLayoutManager: Bool) {
    self.init(usingTextLayoutManager: usingTextLayoutManager)
    frame = frameRect
    delegate = self
    textStorage?.delegate = self
    importsGraphics = false
    allowsUndo = false
  }

  // MARK: - Document synchronization

  var document: LDTXRichTextDocument {
    get throws { try LDTXRichTextDocument(attributedString()) }
  }

  func update(
    document: LDTXRichTextDocument, keys: [LDTXVariableReference],
    names: [LDTXVariableReference: String], isEnabled: Bool
  ) {
    adopting = true
    defer { adopting = false }
    let labelsChanged = self.names != names
    self.keys = keys
    self.names = names
    isEditable = isEnabled
    guard !hasMarkedText() else { return }
    do {
      if lastPublished != document {
        let selection = selectedRange()
        textStorage?.setAttributedString(try converter.decorated(document.attributedString()))
        setSelectedRange(NSRange(location: min(selection.location, string.utf16.count), length: 0))
        lastPublished = document
      } else if labelsChanged {
        textStorage?.setAttributedString(try converter.decorated(attributedString()))
      }
      clearVariableTypingAttributes()
    } catch { onError(error) }
  }

  private var converter: LDTXVariableAttributedTextConverter {
    LDTXVariableAttributedTextConverter(
      baseAttributes: [
        .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
        .foregroundColor: textColor ?? NSColor.textColor,
      ], names: names)
  }

  // MARK: - Editing notifications and typing attributes

  override func didChangeText() {
    super.didChangeText()
    reportChange()
  }

  override func unmarkText() {
    super.unmarkText()
    reportChange()
  }

  private func reportChange() {
    guard !adopting else { return }
    guard !hasMarkedText() else { return }
    do {
      let next = try document
      guard next != lastPublished else { return }
      lastPublished = next
      onDocumentChange(next)
    } catch { onError(error) }
  }

  private func clearVariableTypingAttributes() {
    typingAttributes.removeValue(forKey: .attachment)
  }

  // MARK: - Variable insertion and menus

  func insertVariable(_ key: LDTXVariableReference) {
    guard isEditable, !hasMarkedText(), keys.contains(key) else { return }
    window?.makeFirstResponder(self)
    do {
      var reference = key
      let selection = selectedRange()
      if selection.length == 1,
        let attachment = textStorage?.attribute(
          .attachment, at: selection.location, effectiveRange: nil) as? NSTextAttachment,
        let previous = try? LDTXVariableReference(attachment: attachment)
      {
        reference.body = previous.body
      }
      var attributes = typingAttributes
      attributes.removeValue(forKey: .attachment)
      let text = NSMutableAttributedString(attributedString: try converter.variableText(reference))
      text.addAttributes(attributes, range: NSRange(location: 0, length: text.length))
      insertText(text, replacementRange: selectedRange())
    } catch { onError(error) }
  }

  override func mouseDown(with event: NSEvent) {
    guard isEditable, !hasMarkedText() else {
      super.mouseDown(with: event)
      return
    }
    let point = convert(event.locationInWindow, from: nil)
    let insertion = characterIndexForInsertion(at: point)
    for index in [insertion, insertion - 1] where index >= 0 && index < string.utf16.count {
      guard
        textStorage?.attribute(
          .attachment, at: index, effectiveRange: nil)
          != nil
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

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
    guard isEditable, !hasMarkedText(), !keys.isEmpty else { return menu }
    let insert = NSMenuItem(title: "Insert Variable", action: nil, keyEquivalent: "")
    insert.submenu = variableMenu()
    menu.addItem(.separator())
    menu.addItem(insert)
    return menu
  }

  private func variableMenu() -> NSMenu {
    let menu = NSMenu()
    for key in keys {
      let item = NSMenuItem(
        title: names[key] ?? key.plainText, action: #selector(chooseVariable(_:)), keyEquivalent: ""
      )
      item.target = self
      item.representedObject = key
      menu.addItem(item)
    }
    return menu
  }

  private func showVariableMenu(at point: NSPoint) {
    let menu = variableMenu()
    menu.addItem(.separator())
    let remove = NSMenuItem(
      title: "Remove Variable", action: #selector(removeVariable(_:)), keyEquivalent: "")
    remove.target = self
    menu.addItem(remove)
    menu.popUp(positioning: nil, at: point, in: self)
  }

  @objc private func chooseVariable(_ sender: NSMenuItem) {
    guard let key = sender.representedObject as? LDTXVariableReference else { return }
    insertVariable(key)
  }

  @objc private func removeVariable(_ sender: NSMenuItem) {
    guard isEditable, !hasMarkedText(), selectedRange().length == 1 else { return }
    insertText("", replacementRange: selectedRange())
  }

  // MARK: - Clipboard

  override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.rtfd, .rtf, .string] }

  override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType)
    -> Bool
  {
    guard !hasMarkedText() else { return false }
    do {
      let selected = try LDTXRichTextDocument(
        attributedString().attributedSubstring(from: selectedRange()))
      if type == .rtfd { return pasteboard.setData(selected.rtfd, forType: type) }
      if type == .string { return pasteboard.setString(try selected.plainText(), forType: type) }
      if type == .rtf {
        let text = try selected.expanded { $0.plainText }
        return pasteboard.setData(
          try text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: type
        )
      }
      return super.writeSelection(to: pasteboard, type: type)
    } catch {
      onError(error)
      return false
    }
  }

  override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.rtfd, .rtf, .string] }

  override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType)
    -> Bool
  {
    guard isEditable, !hasMarkedText() else { return false }
    do {
      let text: NSAttributedString
      if type == .rtfd, let data = pasteboard.data(forType: type) {
        text = try LDTXRichTextDocument(rtfd: data).attributedString()
      } else if type == .rtf, let data = pasteboard.data(forType: type) {
        text = try NSAttributedString(
          data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
          documentAttributes: nil)
      } else if type == .string, let string = pasteboard.string(forType: type) {
        text = NSAttributedString(string: string, attributes: typingAttributes)
      } else {
        return false
      }
      try LDTXRichTextDocument.validate(text)
      insertText(try converter.decorated(text), replacementRange: selectedRange())
      return true
    } catch {
      onError(error)
      return false
    }
  }

}

// MARK: - NSTextViewDelegate

extension MacroTextView: NSTextViewDelegate {
  func textViewDidChangeSelection(_ notification: Notification) {
    guard !adopting else { return }
    if !hasMarkedText() { clearVariableTypingAttributes() }
  }
}

extension MacroTextView: @preconcurrency NSTextStorageDelegate {
  func textStorage(
    _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
    range editedRange: NSRange, changeInLength delta: Int
  ) {
    if editedMask.contains(.editedAttributes), !editedMask.contains(.editedCharacters) {
      reportChange()
    }
  }
}
