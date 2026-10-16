// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXVariableStore
import Testing

@Suite struct VariableStoreUnitTestSuite {
  private let text = VariableKey(visionID: 11, item: .text)
  private let label = VariableKey(visionID: 22, item: .label)
  private let confidence = VariableKey(visionID: 22, item: .confidence)

  private func makeStore() -> VariableStore {
    VariableStore(keys: [text, label, confidence])
  }

  @Test func keyIdentityAndPath() throws {
    for item in VariableItem.allCases {
      for id: Int64 in [Int64.min, 0, Int64.max] {
        let key = VariableKey(visionID: id, item: item)
        #expect(try VariableKey(path: key.path) == key)
        #expect(key.id == key)
        #expect(Set([key, try VariableKey(path: key.path)]).count == 1)
      }
    }
    #expect(text.path == "visions/11/text")
    for path in [
      "visions/11", "visions/11/text/", "visions/x/text", "visions/01/text",
      "visions/11/unknown", "other/11/text", "visions/9223372036854775808/text",
    ] {
      #expect(throws: VariableStoreError.invalidPath(path)) { try VariableKey(path: path) }
    }
  }

  @Test func inventoryAndEmptyValues() throws {
    let store = makeStore()
    #expect(store.keys == [text, label, confidence])
    #expect(try store.read(text) == "")
    #expect(try store.read(label) == "")
    #expect(try store.read(confidence) == "0")
    #expect(VariableStore(keys: []).keys.isEmpty)
  }

  @Test func updatesAreAtomicAndCopiesAreIndependent() throws {
    var store = makeStore()
    let independent = store
    try store.update([text: "hello", label: "battle", confidence: "0.75"])
    #expect(try independent.read(text) == "")
    let missing = VariableKey(visionID: 99, item: .text)
    #expect(throws: VariableStoreError.unregisteredKey(missing)) {
      try store.update([text: "changed", missing: "invalid"])
    }
    #expect(try store.read(text) == "hello")
    #expect(throws: VariableStoreError.unregisteredKey(missing)) { try store.read(missing) }
    store.reset(visionID: 22)
    #expect(try store.read(text) == "hello")
    #expect(try store.read(label) == "")
    #expect(try store.read(confidence) == "0")
    try store.update([text: ""])
    #expect(try store.read(text) == "")
  }

  private struct PrefixReader: VariableReader {
    func read(_ value: String, for key: VariableKey) -> String { key.path + ":" + value }
  }

  @Test func delegatesReadingPerKey() throws {
    var store = makeStore()
    try store.update([text: "hello", label: "battle"])
    try store.setReader(PrefixReader(), for: text)
    #expect(try store.read(text) == "visions/11/text:hello")
    #expect(try store.read(label) == "battle")
    let missing = VariableKey(visionID: 99, item: .text)
    #expect(throws: VariableStoreError.unregisteredKey(missing)) {
      try store.setReader(PrefixReader(), for: missing)
    }
  }
}
