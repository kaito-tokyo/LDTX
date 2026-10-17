// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import LDTXVariableStore
import Testing

@Suite struct VariableMacroDocumentUnitTestSuite {
  let key = VariableKey(visionID: 11, item: .text)

  @Test func structuredContentRoundTripsWithoutParsingLiteralTokens() throws {
    let document = VariableMacroDocument(segments: [
      .text("前  \t\n🙂 {{visions/11/text}} "), .variable(key), .text(" 後"), .variable(key),
    ])
    let restored = try VariableMacroDocument(xml: document.xml)
    #expect(restored == document)
    var store = VariableStore(keys: [key])
    try store.update([key: "勝利 {{visions/11/text}}"])
    #expect(
      restored.expand(using: store)
        == "前  \t\n🙂 {{visions/11/text}} 勝利 {{visions/11/text}} 後勝利 {{visions/11/text}}")
  }

  @Test func legacyImportIsExplicitAndStructuredEmptyContentWins() throws {
    var component = Ldtx_Workspace_V4_DynamicTextComponent()
    component.text = "結果：{{visions/11/text}} {{invalid}}"
    #expect(
      try VariableMacroDocument(component: component).segments == [
        .text("結果："), .variable(key), .text(" {{invalid}}"),
      ])
    component.macroDocument = "<macro version=\"1\"/>"
    #expect(try VariableMacroDocument(component: component).segments.isEmpty)
    let restored = try Ldtx_Workspace_V4_DynamicTextComponent(
      serializedBytes: component.serializedData())
    #expect(restored.hasMacroDocument)
    #expect(restored.macroDocument == component.macroDocument)
    #expect(
      VariableMacroDocument(legacyText: "{{visions/0/text}} {{unfinished").plainText
        == "{{visions/0/text}} {{unfinished")
  }

  @Test func missingReferencesRemainEditableAndExpandEmpty() {
    let document = VariableMacroDocument(segments: [
      .text("Before "), .variable(key), .text(" After"),
    ])
    #expect(document.expand(using: VariableStore(keys: [])) == "Before  After")
    #expect(document.segments[1] == .variable(key))
  }

  @Test func rejectsInvalidXMLAndDiscardsPartialContent() {
    for value in [
      "", "<macro/>", "<macro version=\"2\"/>",
      "<macro version=\"1\">valid text<variable vision-id=\"11\" item=\"text\"/>",
      "<macro version=\"1\"><variable vision-id=\"0\" item=\"text\"/></macro>",
      "<macro version=\"1\"><variable vision-id=\"11\" item=\"unknown\"/></macro>",
      "<macro version=\"1\"><variable item=\"text\"/></macro>",
      "<macro version=\"1\"><variable vision-id=\"11\" item=\"text\">body</variable></macro>",
      "<macro version=\"1\"><variable vision-id=\"11\" item=\"text\"><nested/></variable></macro>",
      "<macro version=\"1\"><unknown/></macro>",
      "<macro version=\"1\" extra=\"x\"/>",
      "<!DOCTYPE macro [<!ENTITY secret SYSTEM \"file:///etc/passwd\">]><macro version=\"1\">&secret;</macro>",
      "<!DOCTYPE macro [<!ENTITY value \"expanded\">]><macro version=\"1\">&value;</macro>",
    ] {
      #expect(throws: VariableMacroDocumentError.self, "\(value)") {
        try VariableMacroDocument(xml: value)
      }
    }
  }

  @Test func xmlPreservesEscapesWhitespaceAndSplitCharacterEvents() throws {
    let document = VariableMacroDocument(segments: [
      .text(" &<>\"'\r\n\t 🙂 "), .variable(key), .text(" \n"),
    ])
    #expect(!document.xml.hasPrefix("<?xml"))
    #expect(try VariableMacroDocument(xml: document.xml) == document)
    let xml =
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?><macro version=\"1\">a&amp;<![CDATA[<b>]]> c<variable vision-id=\"11\" item=\"text\"></variable> </macro>"
    #expect(
      try VariableMacroDocument(xml: xml).segments == [
        .text("a&<b> c"), .variable(key), .text(" "),
      ])
    var component = Ldtx_Workspace_V4_DynamicTextComponent()
    component.text = "Must not fall back"
    component.macroDocument = "invalid"
    #expect(throws: VariableMacroDocumentError.self) {
      try VariableMacroDocument(component: component)
    }
  }
}
