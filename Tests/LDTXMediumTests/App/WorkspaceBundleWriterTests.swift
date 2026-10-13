// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletUI
import Testing

@Suite
struct WorkspaceTransientLocalStateIntegrationTestSuite {
  @Test @MainActor func transientLocalStateIsOnlyPersistedAfterSave() throws {
    let suite = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let data = WorkspaceAppletData(userDefaults: defaults)
    let transient = URL(string: "ldtx-untitled://workspace/test")!
    let saved = URL(fileURLWithPath: "/tmp/Saved.ldtxworkspace")
    data.registerTransientState(at: transient)
    data.setState(.init(selectedProgramInternalID: 42), for: transient)
    #expect(data.state(for: transient).selectedProgramInternalID == 42)
    #expect(
      WorkspaceAppletData(userDefaults: defaults).state(for: transient).selectedProgramInternalID
        == nil)
    data.copyState(from: transient, to: saved)
    #expect(
      WorkspaceAppletData(userDefaults: defaults).state(for: saved).selectedProgramInternalID == 42)
  }
}
