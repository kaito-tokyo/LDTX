// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletUI
import Testing

extension AppUIComponentTestSuite.Shard2 {
  @MainActor @Suite
  struct WorkspaceNotificationDelegateUnitTestSuite {
    @Test("LUB-1037: Notification attaches landscape copy and preserves saved files")
    func notificationAttachesLandscapeCopyAndPreservesSavedFiles() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let image = try #require(
        NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
          samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
          bytesPerRow: 0, bitsPerPixel: 0))
      for x in 0..<2 {
        for y in 0..<2 { image.setColor(.red, atX: x, y: y) }
      }
      let data = try #require(image.representation(using: .png, properties: [:]))
      let landscape = root.appendingPathComponent("Landscape.png")
      let portrait = root.appendingPathComponent("Portrait.png")
      try data.write(to: landscape)
      try data.write(to: portrait)
      let capturedAt = Date(timeIntervalSince1970: 1_792_540_800)
      try await Task.detached {
        let content = try WorkspaceNotifications.screenshotContent(
          [
            .init(url: portrait, programCanvas: .portrait, capturedAt: capturedAt),
            .init(url: landscape, programCanvas: .landscape, capturedAt: capturedAt),
          ], attachmentDirectory: root.appendingPathComponent("Attachment"))
        #expect(content.title == "Landscape Program screenshot saved")
        #expect(content.body == capturedAt.formatted(date: .numeric, time: .standard))
        let attachment = try #require(content.attachments.first)
        #expect(content.attachments.count == 1)
        #expect(attachment.identifier == "landscapeProgram")
        #expect(attachment.url.lastPathComponent == "Landscape.png")
        #expect(attachment.url != landscape)
        #expect(try Data(contentsOf: landscape) == data)
        #expect(try Data(contentsOf: portrait) == data)
        #expect(
          content.userInfo["screenshotPaths"] as? [String] == [portrait.path, landscape.path])
      }.value
    }

    @Test("LUB-1037: Notification callbacks are exposed to objective c")
    func notificationCallbacksAreExposedToObjectiveC() {
      // Optional delegate methods must match the SDK to be exposed to Objective-C.
      #expect(
        WorkspaceNotifications.instancesRespond(
          to: NSSelectorFromString(
            "userNotificationCenter:willPresentNotification:withCompletionHandler:")))
      #expect(
        WorkspaceNotifications.instancesRespond(
          to: NSSelectorFromString(
            "userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:")))
    }
  }

  @MainActor
  @Suite("Workspace application termination", .serialized)
  struct WorkspaceApplicationTerminationUnitTestSuite {
    @Test("LUB-1033: Close failure between quit request and shutdown task cancels quit")
    func closeFailureBetweenQuitRequestAndShutdownTaskCancelsQuit() async {
      var failures: [String] = []
      var replies: [Bool] = []
      var presented: [String] = []
      let termination = WorkspaceApplicationTermination(
        hasPendingShutdown: { true },
        shutdown: {
          let result = failures
          failures.removeAll()
          return result
        },
        reply: { _, allowed in replies.append(allowed) },
        presentFailure: { _, error in
          presented.append((error as NSError).localizedFailureReason ?? "")
        })
      #expect(!termination.isTerminationPending)
      #expect(termination.applicationShouldTerminate(.shared) == .terminateLater)
      // Complete an already-closing window synchronously, before the scheduled task runs.
      #expect(termination.isTerminationPending)
      if termination.isTerminationPending { failures.append("Window cleanup failed") }
      while replies.isEmpty { await Task.yield() }
      #expect(presented == ["Window cleanup failed"])
      #expect(replies == [false])
      #expect(!termination.isTerminationPending)
    }

    @Test("LUB-1033: Idle application terminates immediately")
    func idleApplicationTerminatesImmediately() {
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

    @Test("LUB-1033: Repeated quit waits for one shutdown") func repeatedQuitWaitsForOneShutdown()
      async
    {
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

    @Test("LUB-1033: Failure is presented before cancelling quit and can retry")
    func failureIsPresentedBeforeCancellingQuitAndCanRetry() async {
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
    @Test("LUB-1033: Shutdown failures belong to their coordinator")
    func shutdownFailuresBelongToTheirCoordinator() async {
      let first = WorkspaceAppletCoordinator(document: WorkspaceDocument())
      let second = WorkspaceAppletCoordinator(document: WorkspaceDocument())
      await first.shutdown()
      await second.shutdown()
      first.queueShutdownFailure("First recording failed")
      second.queueShutdownFailure("Second recording failed")
      #expect(first.takeShutdownFailureForPresentation() == "First recording failed")
      #expect(first.takeShutdownFailureForPresentation() == nil)
      #expect(second.takeShutdownFailureForPresentation() == "Second recording failed")
    }

    @Test("LUB-1033: Concurrent shutdown releases resources once after cleanup")
    func concurrentShutdownReleasesResourcesOnceAfterCleanup() async {
      let document = WorkspaceDocument()
      let resources = WorkspaceRuntimeFixture()
      var releases = 0
      let coordinator = WorkspaceAppletCoordinator(
        document: document, landscapeRuntime: resources.landscape,
        portraitRuntime: resources.portrait, metalView: resources.metalView,
        captureSessionCoordinator: resources.capture,
        onShutdown: {
          #expect(resources.metalView.delegate == nil)
          #expect(resources.metalView.isPaused)
          releases += 1
        })
      let closing = Task { await coordinator.shutdown() }
      await coordinator.shutdown()
      await closing.value
      await coordinator.shutdown()
      #expect(releases == 1)
    }

  }
}

extension AppUIComponentTestSuite.Shard2 {
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

    @Test("LUB-1033: Waits for every document and coalesces repeated quit")
    func waitsForEveryDocumentAndCoalescesRepeatedQuit() async {
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

    @Test("LUB-1033: Includes documents opened while waiting")
    func includesDocumentsOpenedWhileWaiting() async {
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

    @Test("LUB-1033: Rechecks documents at run loop handoff")
    func rechecksDocumentsAtRunLoopHandoff() async {
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
