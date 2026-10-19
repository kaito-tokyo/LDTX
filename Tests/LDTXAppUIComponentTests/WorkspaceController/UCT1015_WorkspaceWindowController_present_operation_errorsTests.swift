// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1015: present-operation-errors", .serialized)
  @MainActor
  struct UCT1015WorkspaceAppletCoordinatorIntegrationTestSuite {
    @Test func alertAcknowledgesQueuedErrorsInOrder() async throws {
      let state = WorkspaceDocument()
      let window = makeWorkspaceTestWindow(stateService: state)
      defer { window.close() }
      await settleWorkspaceToolbar(window)
      state.operationErrors = [1, 2].map {
        NSError(
          domain: "queue", code: $0,
          userInfo: [NSLocalizedDescriptionKey: "Failure \($0)"])
      }
      for code in [1, 2] {
        var sheet: NSWindow?
        for _ in 0..<200 {
          if let current = window.attachedSheet,
            workspaceDescendants(current.contentView!).contains(where: {
              ($0 as? NSTextField)?.stringValue == "Failure \(code)"
            })
          {
            sheet = current
            break
          }
          try await Task.sleep(for: .milliseconds(10))
        }
        let current = try #require(sheet)
        let button = try #require(
          workspaceDescendants(current.contentView!)
            .compactMap { $0 as? NSButton }.first { $0.title == "OK" })
        button.performClick(nil)
        await settleWorkspaceToolbar(window)
      }
      #expect(state.operationErrors.isEmpty)
    }

    @Test func queuesErrorsAndPreservesDetails() async throws {
      let document = WorkspaceDocument()
      let coordinator = WorkspaceAppletCoordinator(document: document)
      let error = NSError(
        domain: "test", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "Edit failed.",
          NSLocalizedFailureReasonErrorKey: "A retained failure reason.",
          NSLocalizedRecoverySuggestionErrorKey: "Retry the edit.",
        ])
      coordinator.reportError(error)
      coordinator.reportError(NSError(domain: "test", code: 2))
      let state = coordinator.stateService
      #expect(state.operationErrors.first?.code == 1)
      #expect(state.operationErrors.first?.localizedFailureReason == "A retained failure reason.")
      #expect(state.operationErrors.first?.localizedRecoverySuggestion == "Retry the edit.")
      state.operationErrors.removeFirst()
      for _ in 0..<20 {
        if state.operationErrors.first != nil { break }
        await Task.yield()
      }
      #expect(state.operationErrors.first?.code == 2)
      await coordinator.shutdown()
      coordinator.reportError(error)
      #expect(state.operationErrors.first == nil)
    }

    @Test func runtimeFailuresAreScopedAndCanRecurAfterRecovery() async {
      let firstDocument = WorkspaceDocument()
      let secondDocument = WorkspaceDocument()
      let first = WorkspaceAppletCoordinator(document: firstDocument)
      let second = WorkspaceAppletCoordinator(document: secondDocument)
      first.updateMonitorFailure(-50)
      #expect(first.stateService.operationErrors.first != nil)
      #expect(second.stateService.operationErrors.first == nil)
      first.stateService.operationErrors.removeFirst()
      first.updateMonitorFailure(-50)
      #expect(first.stateService.operationErrors.first == nil)
      first.updateMonitorFailure(nil)
      first.updateMonitorFailure(-50)
      #expect(first.stateService.operationErrors.first != nil)
      await first.shutdown()
      await second.shutdown()
    }
  }
}
