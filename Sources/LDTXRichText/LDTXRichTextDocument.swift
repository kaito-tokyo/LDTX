// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UniformTypeIdentifiers

public enum LDTXRichTextError: Error, LocalizedError {
  case invalidDocument, unsupportedAttachment, unsupportedVariable
  public var errorDescription: String? {
    switch self {
    case .invalidDocument: "The rich text document is invalid or uses an unsupported format."
    case .unsupportedAttachment: "Only variable attachments are supported."
    case .unsupportedVariable: "The variable attachment has an unsupported format or version."
    }
  }
}

public struct LDTXVariableReference: Codable, Hashable, Sendable {
  public static let fileType = UTType(exportedAs: "tokyo.kaito.ldtx.variable", conformingTo: .data)
  public let version: Int
  public var id: String
  public var sel: String
  public var body: String

  public init(id: String, sel: String, body: String = "") {
    version = 1
    self.id = id
    self.sel = sel
    self.body = body
  }

  public init(attachment: NSTextAttachment) throws {
    guard let wrapper = attachment.fileWrapper, wrapper.isRegularFile,
      wrapper.preferredFilename?.hasSuffix(".ldtxvar") == true,
      let data = wrapper.regularFileContents
    else { throw LDTXRichTextError.unsupportedAttachment }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == ["version", "id", "sel", "body"]
    else { throw LDTXRichTextError.unsupportedVariable }
    do { self = try JSONDecoder().decode(Self.self, from: data) } catch {
      throw LDTXRichTextError.unsupportedVariable
    }
    guard version == 1 else { throw LDTXRichTextError.unsupportedVariable }
  }

  public func attachment() throws -> NSTextAttachment {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let wrapper = FileWrapper(regularFileWithContents: try encoder.encode(self))
    wrapper.preferredFilename = UUID().uuidString + ".ldtxvar"
    return NSTextAttachment(fileWrapper: wrapper)
  }

  public var plainText: String { "{{\(id)/\(sel)}}" }
}

/// Immutable persisted snapshot. RTFD bytes are retained until a real edit occurs.
public struct LDTXRichTextDocument: Equatable, Sendable {
  public let rtfd: Data

  public init(rtfd: Data) throws {
    guard !rtfd.isEmpty else { throw LDTXRichTextError.invalidDocument }
    let text: NSAttributedString
    do {
      text = try NSAttributedString(
        data: rtfd, options: [.documentType: NSAttributedString.DocumentType.rtfd],
        documentAttributes: nil)
    } catch { throw LDTXRichTextError.invalidDocument }
    try Self.validate(text)
    self.rtfd = rtfd
  }

  public init(_ text: NSAttributedString) throws {
    try Self.validate(text)
    rtfd = try text.data(
      from: NSRange(location: 0, length: text.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    let restored = try NSAttributedString(
      data: rtfd, options: [.documentType: NSAttributedString.DocumentType.rtfd],
      documentAttributes: nil)
    guard restored.string == text.string else {
      throw LDTXRichTextError.invalidDocument
    }
    try Self.validate(restored)
  }

  public func attributedString() throws -> NSAttributedString {
    try NSAttributedString(
      data: rtfd, options: [.documentType: NSAttributedString.DocumentType.rtfd],
      documentAttributes: nil)
  }

  public static func validate(_ text: NSAttributedString) throws {
    var failure: Error?
    text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) {
      value, range, stop in
      guard let value else { return }
      do {
        guard let attachment = value as? NSTextAttachment,
          (text.string as NSString).substring(with: range).allSatisfy({ $0 == "\u{fffc}" })
        else { throw LDTXRichTextError.unsupportedAttachment }
        _ = try LDTXVariableReference(attachment: attachment)
      } catch {
        failure = error
        stop.pointee = true
      }
    }
    if let failure { throw failure }
  }

  /// Replacements inherit the surrounding run's formatting; values are never parsed.
  public func expanded(
    resolve: (LDTXVariableReference) -> String
  ) throws -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: try attributedString())
    var replacements: [(NSRange, LDTXVariableReference)] = []
    var failure: Error?
    result.enumerateAttribute(.attachment, in: NSRange(location: 0, length: result.length)) {
      value, range, _ in
      guard let attachment = value as? NSTextAttachment else { return }
      do {
        let reference = try LDTXVariableReference(attachment: attachment)
        for index in range.location..<NSMaxRange(range) {
          replacements.append((NSRange(location: index, length: 1), reference))
        }
      } catch { failure = error }
    }
    if let failure { throw failure }
    for (range, reference) in replacements.reversed() {
      var attributes = result.attributes(at: range.location, effectiveRange: nil)
      attributes.removeValue(forKey: .attachment)
      result.replaceCharacters(
        in: range, with: NSAttributedString(string: resolve(reference), attributes: attributes))
    }
    return result
  }

  public func plainText() throws -> String { try expanded { $0.plainText }.string }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    if lhs.rtfd == rhs.rtfd { return true }
    guard let left = try? lhs.semanticText(), let right = try? rhs.semanticText() else {
      return false
    }
    return left.isEqual(to: right)
  }

  private func semanticText() throws -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: try attributedString())
    let range = NSRange(location: 0, length: result.length)
    result.enumerateAttributes(in: range) { attributes, range, _ in
      var normalized = attributes
      if let attachment = attributes[.attachment] as? NSTextAttachment,
        let variable = try? LDTXVariableReference(attachment: attachment)
      {
        normalized.removeValue(forKey: .attachment)
        normalized[NSAttributedString.Key("tokyo.kaito.ldtx.variable-value")] =
          [variable.id, variable.sel, variable.body] as NSArray
      }
      result.setAttributes(normalized, range: range)
    }
    return result
  }
}
