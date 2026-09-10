// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspace
import Observation
import Testing

@MainActor
@Suite
struct WorkspaceStoreObservationIntegrationTestSuite {
  @Test func dirtyStateObservationTracksCachedDefinitionChanges() throws {
    let store = try WorkspaceStore(clean: WorkspaceDefinition(name: "Initial"))
    let changed = DispatchSemaphore(value: 0)
    withObservationTracking {
      _ = store.isDirty
    } onChange: {
      changed.signal()
    }

    store.edit { $0.name = "Changed" }

    #expect(changed.wait(timeout: .now() + 1) == .success)
    #expect(store.isDirty)
  }
}
