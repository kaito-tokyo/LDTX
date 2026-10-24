// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import AppKit
import LDTXRichText
import LDTXWorkspaceAppletModel
import Testing

@Suite(.tags(.medium)) struct LDTXRichTextDocumentUnitTestSuite {
  @Test("LUB-1005: Repeated round trips preserve text formatting and variable data")
  func repeatedRoundTripsPreserveTextFormattingAndVariableData() throws {
    let reference = LDTXVariableReference(
      id: " 123🙂 ", sel: "arbitrary selector", body: "\nvalue < 2 && x > 0\r\n\u{0} ]]>")
    let font = NSFont(name: "Helvetica-BoldOblique", size: 27)!
    let text = NSMutableAttributedString(
      string: "日本e\u{301}👨‍👩‍👧‍👦\n", attributes: [.font: font, .foregroundColor: NSColor.red])
    for _ in 0..<2 { text.append(NSAttributedString(attachment: try reference.attachment())) }
    var document = try LDTXRichTextDocument(text)
    for _ in 0..<5 {
      let restored = try LDTXRichTextDocument(rtfd: document.rtfd)
      #expect(restored == document)
      let content = try restored.attributedString()
      #expect(content.string == text.string)
      let restoredFont = content.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
      #expect(restoredFont?.pointSize == 27)
      #expect(restoredFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
      #expect(restoredFont?.fontDescriptor.symbolicTraits.contains(.italic) == true)
      let last = content.length - 1
      let attachment = try #require(
        content.attribute(.attachment, at: last, effectiveRange: nil) as? NSTextAttachment)
      #expect(try LDTXVariableReference(attachment: attachment) == reference)
      document = try LDTXRichTextDocument(content)
      #expect(document == restored)
    }
    let expanded = try document.expanded { _ in "{{literal}} <b>text</b>" }
    #expect(
      expanded.string == "日本e\u{301}👨‍👩‍👧‍👦\n" + String(repeating: "{{literal}} <b>text</b>", count: 2))
    #expect(expanded.attribute(.attachment, at: expanded.length - 1, effectiveRange: nil) == nil)
  }

  @Test("LUB-1005: Attachment filenames and presentation do not identify variables")
  func attachmentFilenamesAndPresentationDoNotIdentifyVariables() throws {
    let reference = LDTXVariableReference(id: "", sel: "", body: "not JavaScript")
    let left = try LDTXRichTextDocument(NSAttributedString(attachment: reference.attachment()))
    let right = try LDTXRichTextDocument(NSAttributedString(attachment: reference.attachment()))
    #expect(left == right)
    #expect(try left.plainText() == "{{/}}")
    let empty = try LDTXRichTextDocument(NSAttributedString(string: ""))
    #expect(!empty.rtfd.isEmpty)
    #expect(try LDTXRichTextDocument(rtfd: empty.rtfd) == empty)
  }

  @Test("LUB-1005: Rejects unsupported formats and attachments")
  func rejectsUnsupportedFormatsAndAttachments() throws {
    for data in [Data(), Data("<macro version=\"1\"/>".utf8), Data([0, 1, 2])] {
      #expect(throws: (any Error).self) { try LDTXRichTextDocument(rtfd: data) }
    }
    for json in [
      #"{"version":2,"id":"1","sel":"x","body":""}"#,
      #"{"version":1,"id":"1","sel":"x"}"#,
      #"{"version":1,"id":1,"sel":"x","body":""}"#,
      #"{"version":1,"id":"1","sel":"x","body":"","extra":true}"#,
    ] {
      let wrapper = FileWrapper(regularFileWithContents: Data(json.utf8))
      wrapper.preferredFilename = "invalid.ldtxvar"
      let text = NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper))
      #expect(throws: (any Error).self) { try LDTXRichTextDocument(text) }
      let raw = try text.data(
        from: NSRange(location: 0, length: text.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
      #expect(throws: (any Error).self) { try LDTXRichTextDocument(rtfd: raw) }
    }
    let foreign = FileWrapper(regularFileWithContents: Data("file".utf8))
    foreign.preferredFilename = "file.txt"
    #expect(throws: (any Error).self) {
      try LDTXRichTextDocument(
        NSAttributedString(attachment: NSTextAttachment(fileWrapper: foreign)))
    }
  }

  @Test("LUB-1005: Workspace dictionary updates are atomic and reset item defaults")
  func workspaceDictionaryUpdatesAreAtomicAndResetItemDefaults() throws {
    let text = LDTXVariableKey(visionID: 11, item: .text)
    let confidence = LDTXVariableKey(visionID: 22, item: .confidence)
    var values = [text: "old", confidence: "0.8"]
    #expect(throws: WorkspaceVariableError.self) {
      try values.update([text: "new", .init(id: "unknown", sel: "x"): "invalid"])
    }
    #expect(values[text] == "old")
    try values.update([text: "new"])
    values.reset(visionID: 22)
    #expect(values[text] == "new")
    #expect(values[confidence] == "0")
  }
}
