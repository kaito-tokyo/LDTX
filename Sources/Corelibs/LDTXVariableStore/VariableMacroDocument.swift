// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos

#if canImport(FoundationXML)
  import FoundationXML
#endif

public enum VariableMacroSegment: Equatable, Sendable {
  case text(String)
  case variable(VariableKey)
}

/// Semantic content shared by persistence, execution, and the editor.
/// Literal strings are never parsed as variable references during editing or evaluation.
public struct VariableMacroDocument: Equatable, Sendable {
  public var segments: [VariableMacroSegment]

  public init(segments: [VariableMacroSegment] = []) {
    self.segments = []
    for segment in segments {
      if case .text(let text) = segment {
        guard !text.isEmpty else { continue }
        if case .text(let previous)? = self.segments.last {
          self.segments[self.segments.count - 1] = .text(previous + text)
          continue
        }
      }
      self.segments.append(segment)
    }
  }

  public func expand(using store: VariableStore) -> String {
    segments.map {
      switch $0 {
      case .text(let text): text
      case .variable(let key): (try? store.read(key)) ?? ""
      }
    }.joined()
  }

  public var plainText: String {
    segments.map {
      switch $0 {
      case .text(let text): text
      case .variable(let key): VariableMacro.token(for: key)
      }
    }.joined()
  }

  /// Compatibility import is explicit and occurs only for the old persisted text field.
  public init(legacyText: String) {
    var remaining = legacyText[...]
    var segments: [VariableMacroSegment] = []
    while let start = remaining.range(of: "{{"),
      let end = remaining[start.upperBound...].range(of: "}}")
    {
      segments.append(.text(String(remaining[..<start.lowerBound])))
      let path = String(remaining[start.upperBound..<end.lowerBound])
      if let key = try? VariableKey(path: path), key.visionID > 0 {
        segments.append(.variable(key))
      } else {
        segments.append(.text(String(remaining[start.lowerBound..<end.upperBound])))
      }
      remaining = remaining[end.upperBound...]
    }
    segments.append(.text(String(remaining)))
    self.init(segments: segments)
  }

  public init(component: Ldtx_Workspace_V4_DynamicTextComponent) throws {
    if component.hasMacroDocument {
      try self.init(xml: component.macroDocument)
    } else {
      self.init(legacyText: component.text)
    }
  }

  public init(xml: String) throws {
    // XMLParser may silently skip external entities rather than reporting an error.
    // This format accepts no DTD syntax, even inside comments or CDATA.
    guard !xml.contains("<!DOCTYPE") else { throw VariableMacroDocumentError.invalidXML }
    let parser = XMLParser(data: Data(xml.utf8))
    let content = MacroXMLParserDelegate()
    parser.delegate = content
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
    guard parser.parse(), !content.failed, content.finished else {
      throw VariableMacroDocumentError.invalidXML
    }
    self.init(segments: content.segments)
  }

  /// Canonical XML without a declaration or formatting whitespace.
  public var xml: String {
    "<macro version=\"1\">"
      + segments.map {
        switch $0 {
        case .text(let text):
          text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r", with: "&#13;")
        case .variable(let key):
          "<variable vision-id=\"\(key.visionID)\" item=\"\(key.item.rawValue)\"/>"
        }
      }.joined() + "</macro>"
  }
}

public enum VariableMacroDocumentError: Error { case invalidXML }

/// Builds a temporary result in one forward pass. Nothing escapes a failed parse.
private final class MacroXMLParserDelegate: NSObject, XMLParserDelegate {
  var segments: [VariableMacroSegment] = []
  var failed = false
  var finished = false
  private var depth = 0

  private func reject(_ parser: XMLParser) {
    failed = true
    parser.abortParsing()
  }

  func parser(
    _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String]
  ) {
    switch depth {
    case 0:
      guard !finished, name == "macro", attributes == ["version": "1"] else {
        reject(parser)
        return
      }
    case 1:
      guard name == "variable", Set(attributes.keys) == ["vision-id", "item"],
        let rawID = attributes["vision-id"], let id = Int64(rawID), id > 0,
        let rawItem = attributes["item"], let item = VariableItem(rawValue: rawItem)
      else {
        reject(parser)
        return
      }
      segments.append(.variable(VariableKey(visionID: id, item: item)))
    default:
      reject(parser)
      return
    }
    depth += 1
  }

  func parser(
    _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
  ) {
    depth -= 1
    if depth == 0 { finished = true }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard depth == 1 else {
      if depth == 2 || !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        reject(parser)
      }
      return
    }
    if case .text(let previous)? = segments.last {
      segments[segments.count - 1] = .text(previous + string)
    } else if !string.isEmpty {
      segments.append(.text(string))
    }
  }

  func parser(_ parser: XMLParser, foundCDATA data: Data) {
    guard let text = String(data: data, encoding: .utf8) else {
      reject(parser)
      return
    }
    self.parser(parser, foundCharacters: text)
  }

  func parser(
    _ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?
  ) { reject(parser) }

  func parser(
    _ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
    publicID: String?, systemID: String?
  ) { reject(parser) }
}
