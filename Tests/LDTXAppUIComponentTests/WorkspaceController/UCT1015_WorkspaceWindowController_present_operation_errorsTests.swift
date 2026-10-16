// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
@testable import LDTXWorkspaceAppletController
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1015: present-operation-errors", .serialized)
  @MainActor
  struct UCT1015WorkspaceRuntimeCoordinatorIntegrationTestSuite {
    @Test func queuesErrorsAndPreservesDetails() async throws {
      let document = WorkspaceDocument()
      let coordinator = WorkspaceRuntimeCoordinator(document: document)
      let error = NSError(domain: "test", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Edit failed.",
        NSLocalizedFailureReasonErrorKey: "A retained failure reason.",
        NSLocalizedRecoverySuggestionErrorKey: "Retry the edit.",
      ])
      coordinator.reportError(error)
      coordinator.reportError(NSError(domain: "test", code: 2))
      let presentation = coordinator.viewState.presentation
      #expect(presentation.operationError?.code == 1)
      #expect(presentation.operationError?.localizedFailureReason == "A retained failure reason.")
      #expect(presentation.operationError?.localizedRecoverySuggestion == "Retry the edit.")
      coordinator.viewState.dismissOperationError()
      for _ in 0..<20 {
        if presentation.operationError != nil { break }
        await Task.yield()
      }
      #expect(presentation.operationError?.code == 2)
      await coordinator.shutdown()
      coordinator.reportError(error)
      #expect(presentation.operationError == nil)
    }

    @Test func runtimeFailuresAreScopedAndCanRecurAfterRecovery() async {
      let firstDocument = WorkspaceDocument()
      let secondDocument = WorkspaceDocument()
      let first = WorkspaceRuntimeCoordinator(document: firstDocument)
      let second = WorkspaceRuntimeCoordinator(document: secondDocument)
      first.updateMonitorFailure(-50)
      #expect(first.viewState.presentation.operationError != nil)
      #expect(second.viewState.presentation.operationError == nil)
      first.viewState.dismissOperationError()
      first.updateMonitorFailure(-50)
      #expect(first.viewState.presentation.operationError == nil)
      first.updateMonitorFailure(nil)
      first.updateMonitorFailure(-50)
      #expect(first.viewState.presentation.operationError != nil)
      await first.shutdown()
      await second.shutdown()
    }
  }
}
