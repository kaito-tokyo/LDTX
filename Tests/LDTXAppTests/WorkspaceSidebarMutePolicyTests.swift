// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import Testing

@testable import LDTXAppUI

@MainActor
struct WorkspaceSidebarMutePolicyTests {
  @Test func muteControlAppearsOnlyForVideoInputs() {
    #expect(WorkspaceSidebarPane.showsMuteControl(for: .video))
    #expect(!WorkspaceSidebarPane.showsMuteControl(for: .audio))
    #expect(!WorkspaceSidebarPane.showsMuteControl(for: .unspecified))
  }

  @Test func videoMuteRemainsEnabledWhileStructuralEditingIsDisabled() {
    #expect(WorkspaceSidebarPane.isMuteControlEnabled(
      for: .video,
      isStructuralEditingEnabled: false
    ))
  }
}
