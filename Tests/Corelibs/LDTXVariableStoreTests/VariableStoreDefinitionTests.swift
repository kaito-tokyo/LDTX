// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import LDTXVariableStore
import Testing

@Suite struct VariableStoreDefinitionUnitTestSuite {
  @Test func projectsDefinitionInventory() throws {
    let store = VariableStore(
      definition: .with {
        $0.visions = [
          .with { $0.ocrVision = .with { $0.internalID = 11 } },
          .with { $0.ldtxSceneDetectorVision = .with { $0.internalID = 22 } },
          .init(),
        ]
      })
    let text = VariableKey(visionID: 11, item: .text)
    let label = VariableKey(visionID: 22, item: .label)
    let confidence = VariableKey(visionID: 22, item: .confidence)
    #expect(store.keys == [text, label, confidence])
    #expect(try store.read(text) == "")
    #expect(try store.read(label) == "")
    #expect(try store.read(confidence) == "0")
    #expect(VariableStore(definition: .init()).keys.isEmpty)
  }
}
