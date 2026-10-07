// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import Testing

@Suite
struct UUIDUnitTestSuite {
  @Test func usesRFC9562ByteOrder() throws {
    let uuid = try #require(UUID(uuidString: "01912345-6789-7abc-8def-0123456789ab"))
    var definition = Ldtx_Envelope_WorkspaceDefinitionEnvelope()
    definition.externalIDAsUUID = uuid
    #expect(definition.externalID == Data([
      0x01, 0x91, 0x23, 0x45, 0x67, 0x89, 0x7a, 0xbc,
      0x8d, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab,
    ]))
    #expect(definition.externalIDAsUUID == uuid)
    let restored = try Ldtx_Envelope_WorkspaceDefinitionEnvelope(
      serializedBytes: definition.serializedData())
    #expect(restored.hasExternalID)
    #expect(restored.externalIDAsUUID == uuid)
    var preferences = Ldtx_Envelope_WorkspacePreferencesEnvelope()
    preferences.externalIDAsUUID = uuid
    #expect(try Ldtx_Envelope_WorkspacePreferencesEnvelope(
      serializedBytes: preferences.serializedData()).externalIDAsUUID == uuid)
  }

  @Test(arguments: [0, 15, 17])
  func rejectsInvalidLengths(count: Int) {
    var definition = Ldtx_Envelope_WorkspaceDefinitionEnvelope()
    definition.externalID = Data(repeating: 0, count: count)
    #expect(definition.externalIDAsUUID == nil)
    var preferences = Ldtx_Envelope_WorkspacePreferencesEnvelope()
    preferences.externalID = definition.externalID
    #expect(preferences.externalIDAsUUID == nil)
    #expect(Ldtx_Envelope_WorkspaceDefinitionEnvelope().externalIDAsUUID == nil)
  }
}
