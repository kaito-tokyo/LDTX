// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletController
import SwiftUI
import Testing

@MainActor
@Suite("Workspace Applet Environment values")
struct WorkspaceAppletDelegateUnitTestSuite {
  private final class FakeDelegate: WorkspaceAppletDelegate {
    func workspaceCoordinator(for document: WorkspaceDocument) -> WorkspaceAppletCoordinator {
      preconditionFailure("Environment value tests must not construct runtime resources")
    }
  }

  @Test func writableKeyPathCanInjectAndReplaceDelegateStartingFromNil() {
    var environment = EnvironmentValues()
    let keyPath = \EnvironmentValues.workspaceAppletDelegate
    #expect(environment[keyPath: keyPath] == nil)
    let first = FakeDelegate()
    environment[keyPath: keyPath] = first
    #expect(environment[keyPath: keyPath] === first)
    let second = FakeDelegate()
    environment[keyPath: keyPath] = second
    #expect(environment[keyPath: keyPath] === second)
    environment[keyPath: keyPath] = nil
    #expect(environment[keyPath: keyPath] == nil)
  }
}
