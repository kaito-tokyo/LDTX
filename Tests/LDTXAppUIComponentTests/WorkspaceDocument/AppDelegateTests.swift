// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletUI
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
      let first = WorkspaceRuntimeCoordinator(document: WorkspaceDocument())
      let second = WorkspaceRuntimeCoordinator(document: WorkspaceDocument())
      await first.shutdown()
      await second.shutdown()
      first.queueShutdownFailure("Recording failed")
      second.queueShutdownFailure("Recording failed")
      #expect(first.takeShutdownFailureForPresentation() == "Recording failed")
      #expect(
        await WorkspaceRuntimeCoordinator.shutdownForApplicationTermination() == [
          "Recording failed"
        ])
      #expect(second.takeShutdownFailureForPresentation() == nil)
      #expect(await WorkspaceRuntimeCoordinator.shutdownForApplicationTermination().isEmpty)
    }

    @Test func ordinaryCloseAcknowledgesItsPresentedFailure() async {
      let controller = WorkspaceRuntimeCoordinator(document: WorkspaceDocument())
      await controller.shutdown()
      controller.queueShutdownFailure("Recording failed")
      #expect(WorkspaceRuntimeCoordinator.hasPendingApplicationShutdown)
      #expect(controller.takeShutdownFailureForPresentation() == "Recording failed")
      #expect(controller.takeShutdownFailureForPresentation() == nil)
      #expect(!WorkspaceRuntimeCoordinator.hasPendingApplicationShutdown)
      #expect(await WorkspaceRuntimeCoordinator.shutdownForApplicationTermination().isEmpty)
    }

    @Test func allControllersIncludingExistingShutdownAreDrained() async {
      let first = WorkspaceRuntimeCoordinator(document: WorkspaceDocument())
      let second = WorkspaceRuntimeCoordinator(document: WorkspaceDocument())
      #expect(WorkspaceRuntimeCoordinator.hasPendingApplicationShutdown)
      let closing = Task { await first.shutdown() }
      let failures = await WorkspaceRuntimeCoordinator.shutdownForApplicationTermination()
      await closing.value
      #expect(failures.isEmpty)
      #expect(!WorkspaceRuntimeCoordinator.hasPendingApplicationShutdown)
      await second.shutdown()
    }
  }
}

extension AppUIComponentTestSuite {
  @MainActor
  @Suite("Document activities before standard termination", .serialized)
  struct WorkspaceDocumentTerminationIntegrationTestSuite {
    @MainActor final class Activity {
      var completion: (() -> Void)?
      func finish() {
        completion?()
        completion = nil
      }
    }

    private func hold(_ document: NSDocument) async -> Activity {
      let activity = Activity()
      let started = AsyncStream<Void>.makeStream()
      document.performActivity(withSynchronousWaiting: false) {
        activity.completion = $0
        started.continuation.yield(())
        started.continuation.finish()
      }
      var iterator = started.stream.makeAsyncIterator()
      _ = await iterator.next()
      return activity
    }

    @Test func waitsForEveryDocumentAndCoalescesRepeatedQuit() async {
      let first = NSDocument()
      let second = NSDocument()
      let firstActivity = await hold(first)
      let secondActivity = await hold(second)
      defer {
        firstActivity.finish()
        secondActivity.finish()
        first.close()
        second.close()
      }
      let termination = WorkspaceDocumentTermination(documents: { [first, second] })
      var calls = 0
      let finished = AsyncStream<Void>.makeStream()
      let proceed: @MainActor () -> Void = {
        calls += 1
        finished.continuation.yield(())
      }
      termination.request(proceed: proceed)
      termination.request(proceed: proceed)
      await Task.yield()
      #expect(calls == 0)
      firstActivity.finish()
      await Task.yield()
      #expect(calls == 0)
      secondActivity.finish()
      var iterator = finished.stream.makeAsyncIterator()
      _ = await iterator.next()
      #expect(calls == 1)
      // A cancelled standard review must allow a later independent Quit.
      termination.request(proceed: proceed)
      _ = await iterator.next()
      #expect(calls == 2)
      finished.continuation.finish()
    }

    @Test func includesDocumentsOpenedWhileWaiting() async {
      let first = NSDocument()
      let second = NSDocument()
      let firstActivity = await hold(first)
      let secondActivity = await hold(second)
      defer {
        firstActivity.finish()
        secondActivity.finish()
        first.close()
        second.close()
      }
      var documents = [first]
      let termination = WorkspaceDocumentTermination(documents: { documents })
      var proceeded = false
      let finished = AsyncStream<Void>.makeStream()
      termination.request {
        proceeded = true
        finished.continuation.yield(())
      }
      await Task.yield()
      documents.append(second)
      firstActivity.finish()
      await Task.yield()
      #expect(!proceeded)
      secondActivity.finish()
      var iterator = finished.stream.makeAsyncIterator()
      _ = await iterator.next()
      #expect(proceeded)
      finished.continuation.finish()
    }

    @Test func rechecksDocumentsAtRunLoopHandoff() async {
      @MainActor final class Inventory {
        var documents: [NSDocument]
        let addedDocument: NSDocument
        var reads = 0
        init(first: NSDocument, second: NSDocument) {
          documents = [first]
          addedDocument = second
        }
      }
      let first = NSDocument()
      let second = NSDocument()
      let secondActivity = await hold(second)
      defer {
        secondActivity.finish()
        first.close()
        second.close()
      }
      let inventory = Inventory(first: first, second: second)
      let changed = AsyncStream<Void>.makeStream()
      let finished = AsyncStream<Void>.makeStream()
      var proceeded = false
      let termination = WorkspaceDocumentTermination(documents: {
        inventory.reads += 1
        if inventory.reads == 2 {
          RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
              inventory.documents.append(inventory.addedDocument)
              changed.continuation.yield(())
            }
          }
        }
        return inventory.documents
      })
      termination.request {
        proceeded = true
        finished.continuation.yield(())
      }
      var changes = changed.stream.makeAsyncIterator()
      _ = await changes.next()
      #expect(!proceeded)
      secondActivity.finish()
      var completion = finished.stream.makeAsyncIterator()
      _ = await completion.next()
      #expect(proceeded)
      #expect(inventory.reads >= 5)
      changed.continuation.finish()
      finished.continuation.finish()
    }
  }
}
