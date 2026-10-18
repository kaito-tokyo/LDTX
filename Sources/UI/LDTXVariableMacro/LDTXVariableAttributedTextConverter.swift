// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXRichText

@MainActor
struct LDTXVariableAttributedTextConverter {
  let baseAttributes: [NSAttributedString.Key: Any]
  let names: [LDTXVariableReference: String]

  func decorated(_ text: NSAttributedString) throws -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: text)
    var replacements: [(NSRange, NSTextAttachment)] = []
    var failure: Error?
    text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) {
      value, range, _ in
      guard let attachment = value as? NSTextAttachment else { return }
      do {
        let key = try LDTXVariableReference(attachment: attachment)
        let value = try variableText(key)
        replacements.append(
          (range, value.attribute(.attachment, at: 0, effectiveRange: nil) as! NSTextAttachment))
      } catch { failure = error }
    }
    if let failure { throw failure }
    for (range, attachment) in replacements {
      result.addAttribute(.attachment, value: attachment, range: range)
    }
    return result
  }

  func variableText(_ key: LDTXVariableReference) throws -> NSAttributedString {
    let label =
      names.first { $0.key.id == key.id && $0.key.sel == key.sel }?.value
      ?? "Missing: \(key.plainText)"
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
    let attachment = try key.attachment()
    attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
    attachment.bounds = CGRect(x: 0, y: -6, width: width, height: 24)
    attachment.allowsTextAttachmentView = false
    let value = NSMutableAttributedString(attachment: attachment)
    value.addAttributes(
      baseAttributes,
      range: NSRange(location: 0, length: 1))
    return value
  }

}
