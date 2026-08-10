// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspace
import Testing

struct WorkspaceResourcePathComponentCodecTests {
  @Test func encodesWorkspaceReservedPathCharacters() {
    #expect(WorkspaceResourcePathComponentCodec.encode(".") == "%2E")
    #expect(WorkspaceResourcePathComponentCodec.encode("..") == "%2E%2E")
    #expect(WorkspaceResourcePathComponentCodec.encode("a/b%") == "a%2Fb%25")
    #expect(WorkspaceResourcePathComponentCodec.encode("a\0b") == "a%00b")
  }

  @Test func leavesOtherCharactersUnchanged() {
    #expect(WorkspaceResourcePathComponentCodec.encode("日本語 Name") == "日本語 Name")
  }
}
