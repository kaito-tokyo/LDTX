// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletUI
import Testing

extension AppUIComponentTestSuite {
  @Suite @MainActor
  struct WorkspaceActionIntegrationTestSuite {
    @Test(.timeLimit(.minutes(1)))
    func failedClosePresentsCaptureAndCleanupErrorsWithoutRetryReplay() async throws {
      let document = WorkspaceDocument()
      var releasedError: String?
      var released = false
      var coordinator: WorkspaceAppletCoordinator!
      coordinator = WorkspaceAppletCoordinator(
        document: document,
        onShutdown: {
          released = true
          releasedError = coordinator.takeShutdownFailureForPresentation()
        })
      var resume: CheckedContinuation<Void, Never>?
      let capture = Task {
        _ = try? await coordinator.captureScreenshots {
          await withCheckedContinuation { resume = $0 }
          throw NSError(
            domain: "Capture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Screenshot write failed"])
        }
      }
      while resume == nil { await Task.yield() }
      let close = Task {
        await coordinator.closeWorkspace(afterCleanup: {
          throw NSError(
            domain: "Cleanup", code: 2,
            userInfo: [
              NSLocalizedDescriptionKey: "Cleanup failed",
              NSLocalizedRecoverySuggestionErrorKey: "Retry cleanup",
            ])
        })
      }
      while !coordinator.isClosing { await Task.yield() }
      resume?.resume()
      await capture.value
      guard case .failed(let error) = await close.value else {
        Issue.record("Expected failed close")
        return
      }
      #expect(error.localizedDescription == "Cleanup failed")
      #expect(error.localizedFailureReason?.contains("Screenshot write failed") == true)
      #expect(error.localizedRecoverySuggestion == "Retry cleanup")
      let displayed = try #require(document.operationErrors.last)
      #expect(displayed.localizedFailureReason?.contains("Screenshot write failed") == true)
      #expect(!released)
      #expect(coordinator.takeShutdownFailureForPresentation() == nil)
      guard case .succeeded = await coordinator.closeWorkspace() else {
        Issue.record("Retry should close")
        return
      }
      #expect(released)
      #expect(releasedError == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func streamDeckCapturesBelongToTheirWorkspaceAcrossFocusChanges() async {
      let first = WorkspaceAppletCoordinator(document: WorkspaceDocument())
      let second = WorkspaceAppletCoordinator(document: WorkspaceDocument())
      let firstID = first.stateService.runtimeID
      let secondID = second.stateService.runtimeID
      var target = first
      var resumes: [UUID: CheckedContinuation<Void, Never>] = [:]
      let deck = WorkspaceStreamDeck(
        target: { target }, generationValidator: { $0 == 1 },
        performAction: { coordinator, _ in
          await withCheckedContinuation { resumes[coordinator.stateService.runtimeID] = $0 }
        })
      deck.refresh()
      let firstFrame = deck.published
      let firstCapture = Task { await deck.pressed(2, frame: firstFrame, generation: 1) }
      while resumes[firstID] == nil { await Task.yield() }
      target = second
      deck.refresh()
      #expect(deck.published.enabled[2])
      let secondFrame = deck.published
      var started = false
      let secondCapture = Task {
        started = true
        await deck.pressed(2, frame: secondFrame, generation: 1)
      }
      while !started { await Task.yield() }
      #expect(resumes.count == 2)
      target = first
      deck.refresh()
      #expect(!deck.published.enabled[2])
      target = second
      deck.refresh()
      #expect(!deck.published.enabled[2])
      resumes[firstID]?.resume()
      await firstCapture.value
      deck.refresh()
      #expect(!deck.published.enabled[2])
      target = first
      deck.refresh()
      #expect(deck.published.enabled[2])
      resumes[secondID]?.resume()
      await secondCapture.value
      target = second
      deck.refresh()
      #expect(deck.published.enabled[2])
      await first.shutdown()
      await second.shutdown()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func closingCaptureFailuresReachApplicationOwnerOnce(
      distinctErrors: Bool, reverseCompletion: Bool
    ) async throws {
      let document = WorkspaceDocument()
      var releasedError: String?
      var coordinator: WorkspaceAppletCoordinator!
      coordinator = WorkspaceAppletCoordinator(
        document: document,
        onShutdown: {
          releasedError = coordinator.takeShutdownFailureForPresentation()
        })
      // A failure observed before closing belongs to the window, not a later close.
      do {
        _ = try await coordinator.captureScreenshots { throw CocoaError(.fileReadUnknown) }
      } catch { coordinator.reportError(error) }
      #expect(document.operationErrors.count == 1)
      #expect(coordinator.takeShutdownFailureForPresentation() == nil)
      var notifications = 0
      coordinator.screenshotsDidSave = { _ in notifications += 1 }
      let messages = [
        "First screenshot failed",
        distinctErrors ? "Second screenshot failed" : "First screenshot failed",
      ]
      var resumes: [CheckedContinuation<Void, Never>] = []
      var captures: [Task<Void, Never>] = []
      for message in messages {
        let capture = Task {
          do {
            _ = try await coordinator.captureScreenshots {
              await withCheckedContinuation { resumes.append($0) }
              throw NSError(
                domain: "ScreenshotTest", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
            }
          } catch {
            // Same policy as perform: closing failures go to the application owner.
            if !coordinator.isClosing { coordinator.reportError(error) }
          }
        }
        captures.append(capture)
        // Establish admission order independently of task scheduling.
        while resumes.count != captures.count { await Task.yield() }
      }
      let close = Task { await coordinator.closeWorkspace() }
      while !coordinator.isClosing { await Task.yield() }
      let completionOrder = reverseCompletion ? [1, 0] : [0, 1]
      for index in completionOrder {
        resumes[index].resume()
        await captures[index].value
      }
      guard case .succeeded = await close.value else {
        Issue.record("Cleanup should succeed")
        return
      }
      // Failures are presented in arrival order, with duplicate messages removed.
      let expectedMessages = distinctErrors ? completionOrder.map { messages[$0] } : [messages[0]]
      #expect(releasedError == expectedMessages.joined(separator: "\n\n"))
      #expect(document.operationErrors.isEmpty)
      #expect(coordinator.takeShutdownFailureForPresentation() == nil)
      #expect(notifications == 0)
      let next = WorkspaceAppletCoordinator(document: WorkspaceDocument())
      await next.shutdown()
      #expect(next.takeShutdownFailureForPresentation() == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func idleShutdownWaitsForAcceptedCapture(fails: Bool) async throws {
      let document = WorkspaceDocument()
      var released = false
      let coordinator = WorkspaceAppletCoordinator(
        document: document, onShutdown: { released = true })
      var notifications = 0
      coordinator.screenshotsDidSave = { _ in notifications += 1 }
      var resume: CheckedContinuation<Void, Never>?
      let capture = Task {
        try await coordinator.captureScreenshots {
          await withCheckedContinuation { resume = $0 }
          if fails { throw CocoaError(.fileWriteUnknown) }
          return [
            WorkspaceScreenshot(
              url: URL(fileURLWithPath: "/tmp/accepted.jpg"),
              programCanvas: .landscape, capturedAt: Date())
          ]
        }
      }
      while resume == nil { await Task.yield() }
      var secondResume: CheckedContinuation<Void, Never>?
      let second = Task {
        try await coordinator.captureScreenshots {
          await withCheckedContinuation { secondResume = $0 }
          return [
            WorkspaceScreenshot(
              url: URL(fileURLWithPath: "/tmp/second.jpg"),
              programCanvas: .portrait, capturedAt: Date())
          ]
        }
      }
      while secondResume == nil { await Task.yield() }
      let shutdown = Task { await coordinator.shutdown() }
      while !coordinator.isClosing && !released { await Task.yield() }
      // Let unrelated shutdown stages finish; the accepted save remains blocked.
      try await Task.sleep(for: .seconds(1))
      #expect(!released)
      #expect(!document.isClosed)
      #expect(notifications == 0)
      var lateCaptureStarted = false
      do {
        _ = try await coordinator.captureScreenshots {
          lateCaptureStarted = true
          return []
        }
        Issue.record("Closing must reject new captures")
      } catch {}
      #expect(!lateCaptureStarted)
      resume?.resume()
      _ = await capture.result
      #expect(!released)
      #expect(notifications == (fails ? 0 : 1))
      secondResume?.resume()
      _ = await second.result
      await shutdown.value
      #expect(released)
      #expect(document.isClosed)
      #expect(notifications == (fails ? 1 : 2))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [0, 1])
    func streamDeckOutputControlsRemainAvailableDuringCapture(outputKey: Int) async {
      let document = WorkspaceDocument()
      let coordinator = WorkspaceAppletCoordinator(document: document)
      document.recordingState = .recording
      var actions: [WorkspaceAction] = []
      var outputResume: CheckedContinuation<Void, Never>?
      var resume: CheckedContinuation<Void, Never>?
      let deck = WorkspaceStreamDeck(
        target: { coordinator }, generationValidator: { $0 == 1 },
        performAction: {
          _, action in
          actions.append(action)
          if action == .captureScreenshots {
            await withCheckedContinuation { resume = $0 }
          } else {
            await withCheckedContinuation { outputResume = $0 }
          }
        })
      deck.refresh()
      let captureFrame = deck.published
      let capture = Task { await deck.pressed(2, frame: captureFrame, generation: 1) }
      while resume == nil { await Task.yield() }
      deck.refresh()
      let savingFrame = deck.published
      #expect(savingFrame.enabled[0])
      #expect(savingFrame.enabled[1])
      #expect(!savingFrame.enabled[2])
      await deck.pressed(2, frame: savingFrame, generation: 1)
      await deck.pressed(outputKey, frame: savingFrame, generation: 2)
      var wrongTarget = savingFrame
      wrongTarget.target = UUID()
      await deck.pressed(outputKey, frame: wrongTarget, generation: 1)
      #expect(actions == [.captureScreenshots])
      let output = Task { await deck.pressed(outputKey, frame: savingFrame, generation: 1) }
      while outputResume == nil { await Task.yield() }
      #expect(actions == [.captureScreenshots, outputKey == 0 ? .stopOutput : .startPauseOutput])
      resume?.resume()
      await capture.value
      deck.refresh()
      // A completed capture must not clear the overlapping output command's lock.
      #expect(deck.published.enabled.allSatisfy { !$0 })
      outputResume?.resume()
      await output.value
      deck.refresh()
      #expect(deck.published.enabled[2])
      await coordinator.shutdown()
    }

    @Test func successIsPublishedOnlyAfterCaptureCompletes() async throws {
      let document = WorkspaceDocument()
      let coordinator = WorkspaceAppletCoordinator(document: document)
      defer { coordinator.screenshotsDidSave = nil }
      let screenshot = WorkspaceScreenshot(
        url: URL(fileURLWithPath: "/tmp/test.jpg"),
        programCanvas: .landscape, capturedAt: Date())
      var notifications: [[WorkspaceScreenshot]] = []
      coordinator.screenshotsDidSave = { notifications.append($0) }
      var resume: CheckedContinuation<Void, Never>?
      let task = Task {
        try await coordinator.captureScreenshots {
          await withCheckedContinuation { resume = $0 }
          return [screenshot]
        }
      }
      while resume == nil { await Task.yield() }
      #expect(notifications.isEmpty)
      resume?.resume()
      let result = try await task.value
      #expect(result.map(\.url) == [screenshot.url])
      #expect(notifications.count == 1)
      #expect(notifications.first?.map(\.url) == [screenshot.url])
      do {
        _ = try await coordinator.captureScreenshots {
          await Task.yield()
          throw CocoaError(.fileWriteUnknown)
        }
        Issue.record("A failed save must propagate its error")
      } catch { #expect(notifications.count == 1) }
      await coordinator.shutdown()
    }

    @Test func failedAndClosedCaptureDoNotPublishSuccess() async {
      let document = WorkspaceDocument()
      let coordinator = WorkspaceAppletCoordinator(document: document)
      var notifications = 0
      coordinator.screenshotsDidSave = { _ in notifications += 1 }
      document.outputFailureMessage = "Existing output failure"
      #expect(coordinator.actionState(.captureScreenshots).isEnabled)
      let failed = await coordinator.perform(.captureScreenshots)
      #expect(failed == nil)
      #expect(notifications == 0)
      #expect(document.outputFailureMessage == "Existing output failure")
      await coordinator.shutdown()
      let errorCount = document.operationErrors.count
      for action in WorkspaceAction.allCases {
        #expect(!coordinator.actionState(action).isEnabled)
        let result = await coordinator.perform(action)
        #expect(result == nil)
      }
      #expect(document.operationErrors.count == errorCount)
      #expect(notifications == 0)
    }
  }

  @Suite @MainActor
  struct WorkspaceOutputControlsUnitTestSuite {
    @Test func savedUnsavedTransitionAndClosedAdmission() {
      let document = WorkspaceDocument()
      let states: [WorkspaceRecordingState] = [
        .idle, .starting, .recording, .pausing, .paused, .stopping, .failed("failure"),
      ]
      for state in states {
        document.recordingState = state
        let saved = WorkspaceOutputControls(stateService: document, hasSavedURL: true)
        let unsaved = WorkspaceOutputControls(stateService: document, hasSavedURL: false)
        #expect(saved.showsPause == (state == .recording))
        #expect(saved.stopEnabled == state.canStop)
        #expect(saved.startPauseEnabled == (state.canStart || state == .recording))
        #expect(unsaved.startPauseEnabled == (state == .recording))
        #expect(saved.screenshotEnabled)
        #expect(saved.state(for: .stopOutput, hasRecording: true).isEnabled == state.canStop)
        #expect(
          saved.state(for: .startPauseOutput, hasRecording: true).isEnabled
            == (state.canStart || state == .recording))
        #expect(saved.state(for: .captureScreenshots, hasRecording: false).isEnabled)
        #expect(saved.state(for: .showRecordingInFinder, hasRecording: true).isEnabled)
        #expect(!saved.state(for: .showRecordingInFinder, hasRecording: false).isEnabled)
        let closing = WorkspaceOutputControls(
          stateService: document, hasSavedURL: true, isClosing: true)
        #expect(!document.isClosed)
        #expect(!closing.stopEnabled && !closing.startPauseEnabled && !closing.screenshotEnabled)
        for action in WorkspaceAction.allCases {
          #expect(!closing.state(for: action, hasRecording: true).isEnabled)
        }
      }
      document.isClosed = true
      let closed = WorkspaceOutputControls(stateService: document, hasSavedURL: true)
      #expect(!closed.stopEnabled && !closed.startPauseEnabled && !closed.screenshotEnabled)
      for action in WorkspaceAction.allCases {
        #expect(!closed.state(for: action, hasRecording: true).isEnabled)
      }
    }
  }
}
