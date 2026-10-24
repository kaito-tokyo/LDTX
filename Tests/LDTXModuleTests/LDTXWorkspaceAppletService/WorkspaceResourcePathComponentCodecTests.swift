// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@testable import LDTXWorkspaceAppletService
import Testing

@Suite(.tags(.easy))
struct WorkspaceResourcePathComponentCodecUnitTestSuite {
  @Test("LUB-1029: Encodes workspace reserved path characters")
  func encodesWorkspaceReservedPathCharacters() {
    #expect(WorkspaceResourcePathComponentCodec.encode(".") == "%2E")
    #expect(WorkspaceResourcePathComponentCodec.encode("..") == "%2E%2E")
    #expect(WorkspaceResourcePathComponentCodec.encode("a/b%") == "a%2Fb%25")
    #expect(WorkspaceResourcePathComponentCodec.encode("a\0b") == "a%00b")
  }

  @Test("LUB-1029: Leaves other characters unchanged") func leavesOtherCharactersUnchanged() {
    #expect(WorkspaceResourcePathComponentCodec.encode("日本語 Name") == "日本語 Name")
  }
}
