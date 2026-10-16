// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
@testable import LDTXWorkspaceAppletController
import Testing

extension AppUIComponentTestSuite {
  @MainActor
  @Suite("Workspace application termination", .serialized)
  struct WorkspaceApplicationTerminationUnitTestSuite {
    @Test func idleApplicationTerminatesImmediately() {
      let delegate = WorkspaceApplicationTermination(
        hasPendingShutdown: { false },
        shutdown: {
          Issue.record("Unexpected shutdown")
          return []
        },
        reply: { _, _ in Issue.record("Unexpected reply") },
        presentFailure: { _, _ in Issue.record("Unexpected failure") })
      #expect(delegate.applicationShouldTerminate(.shared) == .terminateNow)
    }

    @Test func repeatedQuitWaitsForOneShutdown() async {
      var continuation: CheckedContinuation<Void, Never>?
      var calls = 0
      var replies: [Bool] = []
      let delegate = WorkspaceApplicationTermination(
        hasPendingShutdown: { true },
        shutdown: {
          calls += 1
          await withCheckedContinuation { continuation = $0 }
          return []
        }, reply: { _, allowed in replies.append(allowed) },
        presentFailure: { _, _ in Issue.record("Unexpected failure") })
      #expect(delegate.applicationShouldTerminate(.shared) == .terminateLater)
      while continuation == nil { await Task.yield() }
      #expect(delegate.applicationShouldTerminate(.shared) == .terminateLater)
      #expect(calls == 1)
      #expect(replies.isEmpty)
      continuation?.resume()
      while replies.isEmpty { await Task.yield() }
      #expect(replies == [true])
    }

    @Test func failureIsPresentedBeforeCancellingQuitAndCanRetry() async {
      var attempts = 0
      var events: [String] = []
      let delegate = WorkspaceApplicationTermination(
        hasPendingShutdown: { true },
        shutdown: {
          attempts += 1
          return attempts == 1 ? ["Upload failed", "Recording failed"] : []
        },
        reply: { _, allowed in events.append(allowed ? "allow" : "cancel") },
        presentFailure: { _, error in
          #expect((error as NSError).localizedFailureReason == "Upload failed\nRecording failed")
          events.append("error")
        })
      #expect(delegate.applicationShouldTerminate(.shared) == .terminateLater)
      while events.count < 2 { await Task.yield() }
      #expect(events == ["error", "cancel"])
      #expect(delegate.applicationShouldTerminate(.shared) == .terminateLater)
      while events.count < 3 { await Task.yield() }
      #expect(events == ["error", "cancel", "allow"])
      #expect(attempts == 2)
    }

  }

  @MainActor
  @Suite("Workspace termination lifecycle", .serialized)
  struct WorkspaceTerminationIntegrationTestSuite {
    @Test func acknowledgingOneCloseDoesNotConsumeAnotherWindowsFailure() async {
      let first = WorkspaceWindowController(document: WorkspaceDocument())
      let second = WorkspaceWindowController(document: WorkspaceDocument())
      await first.shutdown()
      await second.shutdown()
      first.queueShutdownFailure("Recording failed")
      second.queueShutdownFailure("Recording failed")
      #expect(first.takeShutdownFailureForPresentation() == "Recording failed")
      #expect(
        await WorkspaceWindowController.shutdownForApplicationTermination() == ["Recording failed"])
      #expect(second.takeShutdownFailureForPresentation() == nil)
      #expect(await WorkspaceWindowController.shutdownForApplicationTermination().isEmpty)
    }

    @Test func ordinaryCloseAcknowledgesItsPresentedFailure() async {
      let controller = WorkspaceWindowController(document: WorkspaceDocument())
      await controller.shutdown()
      controller.queueShutdownFailure("Recording failed")
      #expect(WorkspaceWindowController.hasPendingApplicationShutdown)
      #expect(controller.takeShutdownFailureForPresentation() == "Recording failed")
      #expect(controller.takeShutdownFailureForPresentation() == nil)
      #expect(!WorkspaceWindowController.hasPendingApplicationShutdown)
      #expect(await WorkspaceWindowController.shutdownForApplicationTermination().isEmpty)
    }

    @Test func allControllersIncludingExistingShutdownAreDrained() async {
      let first = WorkspaceWindowController(document: WorkspaceDocument())
      let second = WorkspaceWindowController(document: WorkspaceDocument())
      #expect(WorkspaceWindowController.hasPendingApplicationShutdown)
      let closing = Task { await first.shutdown() }
      let failures = await WorkspaceWindowController.shutdownForApplicationTermination()
      await closing.value
      #expect(failures.isEmpty)
      #expect(!WorkspaceWindowController.hasPendingApplicationShutdown)
      await second.shutdown()
    }
  }
}
