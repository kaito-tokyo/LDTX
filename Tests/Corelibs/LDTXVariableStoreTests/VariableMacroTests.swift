// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXVariableStore
import Testing

@Suite struct VariableMacroUnitTestSuite {
  @Test func expandsRepeatedVariablesAndUnicodeWithoutRecursion() throws {
    let text = VariableKey(visionID: 11, item: .text)
    let label = VariableKey(visionID: 22, item: .label)
    var store = VariableStore(keys: [text, label])
    try store.update([text: "勝利 {{visions/22/label}}", label: "battle"])
    #expect(
      VariableMacro.expand(
        "結果：{{visions/11/text}}\n{{visions/22/label}} / {{visions/22/label}}", using: store)
        == "結果：勝利 {{visions/22/label}}\nbattle / battle")
    try store.update([label: "result"])
    #expect(VariableMacro.expand(VariableMacro.token(for: label), using: store) == "result")
    store.reset(visionID: 22)
    #expect(VariableMacro.expand(VariableMacro.token(for: label), using: store).isEmpty)
  }

  @Test func missingValuesAndMalformedTokens() {
    let store = VariableStore(keys: [])
    #expect(VariableMacro.expand("A{{visions/99/text}}B", using: store) == "AB")
    #expect(VariableMacro.expand("{{visions/99/confidence}}", using: store) == "")
    for text in ["日本語", "{{unknown}}", "{{visions/1/text", "{{visions/01/text}}"] {
      #expect(VariableMacro.expand(text, using: store) == text)
    }
  }
}
