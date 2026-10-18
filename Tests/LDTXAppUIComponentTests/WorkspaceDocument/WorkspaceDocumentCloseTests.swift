// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceBundleFormat
import Synchronization
import Testing

extension AppUIComponentTestSuite {
  @Suite("Workspace asynchronous close", .serialized)
  @MainActor
  struct WorkspaceDocumentCloseIntegrationTestSuite {
    @Test func pendingActivityDefersAndCoalescesCloseWithoutBlockingMainActor() async throws {
      let document = NSDocument()
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let controller = NSWindowController(window: window)
      document.addWindowController(controller)
      let target = CloseTarget()
      let button = try #require(window.standardWindowButton(.closeButton))
      button.target = target
      button.action = #selector(CloseTarget.close(_:))
      let gate = WorkspaceDocumentCloseCoordinator()
      gate.attach(to: window)
      defer {
        gate.detach()
        document.close()
      }
      var finishActivity: (() -> Void)?
      let activityStarted = AsyncStream<Void>.makeStream()
      document.performActivity(withSynchronousWaiting: false) {
        finishActivity = $0
        activityStarted.continuation.yield(())
        activityStarted.continuation.finish()
      }
      var activity = activityStarted.stream.makeAsyncIterator()
      _ = await activity.next()
      #expect(finishActivity != nil)
      for _ in 0..<3 {
        NSApplication.shared.sendAction(
          try #require(button.action), to: button.target, from: button)
      }
      #expect(target.calls == 0)
      // This MainActor work must run while closure is queued behind document activity.
      await Task.yield()
      #expect(target.calls == 0)
      finishActivity?()
      finishActivity = nil
      for _ in 0..<100 where target.calls == 0 { await Task.yield() }
      #expect(target.calls == 1)
      gate.detach()
      #expect(button.target === target)
      #expect(button.action == #selector(CloseTarget.close(_:)))
    }

    @Test func detachAndReattachRejectsAnEarlierQueuedClose() async throws {
      let document = NSDocument()
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      document.addWindowController(NSWindowController(window: window))
      let button = try #require(window.standardWindowButton(.closeButton))
      let target = CloseTarget()
      button.target = target
      button.action = #selector(CloseTarget.close(_:))
      var gate: WorkspaceDocumentCloseCoordinator? = WorkspaceDocumentCloseCoordinator()
      gate?.attach(to: window)
      defer {
        gate?.detach()
        document.close()
      }
      let started = AsyncStream<Void>.makeStream()
      var finish: (() -> Void)?
      document.performActivity(withSynchronousWaiting: false) {
        finish = $0
        started.continuation.yield(())
        started.continuation.finish()
      }
      var waiting = started.stream.makeAsyncIterator()
      _ = await waiting.next()
      NSApplication.shared.sendAction(try #require(button.action), to: button.target, from: button)
      gate?.detach()
      gate?.attach(to: window)
      finish?()
      finish = nil
      let drained = AsyncStream<Void>.makeStream()
      document.performActivity(withSynchronousWaiting: false) { completion in
        completion()
        drained.continuation.yield(())
        drained.continuation.finish()
      }
      var completed = drained.stream.makeAsyncIterator()
      _ = await completed.next()
      #expect(target.calls == 0)
      gate = nil
      #expect(button.target === target)
      #expect(button.action == #selector(CloseTarget.close(_:)))
    }

    @Test func repeatedSaveWhileWritingThenCloseKeepsLatestContent() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("ldtxworkspace")
      defer { try? FileManager.default.removeItem(at: root) }
      let source = WorkspaceDocument()
      let baseline = try await source.snapshot(
        contentType: WorkspaceDocument.readableContentTypes[0])
      try WorkspaceBundleWriterV4().write(baseline, to: root)
      source.stateService.workspaceDefinition.displayName = "First save"
      let first = try await source.snapshot(contentType: WorkspaceDocument.readableContentTypes[0])
      let document = SaveBridgeDocument(snapshot: first)
      document.fileURL = root
      document.fileType = WorkspaceDocument.readableContentTypes[0].identifier
      document.updateChangeCount(.changeDone)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      document.addWindowController(NSWindowController(window: window))
      let gate = WorkspaceDocumentCloseCoordinator()
      gate.attach(to: window)
      let actions = WorkspaceDocumentActions(stateService: source.stateService, window: window)
      let closed = AsyncStream<Void>.makeStream()
      let observer = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: window, queue: .main
      ) { _ in
        closed.continuation.yield(())
        closed.continuation.finish()
      }
      defer {
        document.release.signal()
        gate.detach()
        document.close()
        NotificationCenter.default.removeObserver(observer)
      }
      var started = document.started.stream.makeAsyncIterator()
      actions.saveDocument(nil)
      _ = await started.next()
      let termination = WorkspaceDocumentTermination(documents: { [document] })
      let reviewed = AsyncStream<Void>.makeStream()
      var reviews = 0
      termination.request {
        reviews += 1
        reviewed.continuation.yield(())
      }
      termination.request { Issue.record("A repeated pending Quit must be coalesced") }

      source.stateService.workspaceDefinition.displayName = "Latest queued save"
      let latest = try await source.snapshot(contentType: WorkspaceDocument.readableContentTypes[0])
      document.snapshot.withLock { $0 = latest }
      document.updateChangeCount(.changeDone)
      actions.saveDocument(nil)
      let button = try #require(window.standardWindowButton(.closeButton))
      NSApplication.shared.sendAction(try #require(button.action), to: button.target, from: button)
      document.release.signal()
      _ = await started.next()
      document.release.signal()
      var didClose = closed.stream.makeAsyncIterator()
      _ = await didClose.next()
      var review = reviewed.stream.makeAsyncIterator()
      _ = await review.next()
      reviewed.continuation.finish()
      #expect(reviews == 1)
      #expect(!document.timedOut.withLock { $0 })
      #expect(try WorkspaceBundleReaderV4(at: root).read() == latest)
    }

    @Test(arguments: [1, 3])
    func delayedSaveThenClosePersistsLatestCapturedContent(saveCount: Int) async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("ldtxworkspace")
      defer { try? FileManager.default.removeItem(at: root) }
      let source = WorkspaceDocument()
      source.stateService.workspaceDefinition.displayName = "Latest confirmed content"
      let snapshot = try await source.snapshot(
        contentType: WorkspaceDocument.readableContentTypes[0])
      let document = SaveBridgeDocument(snapshot: snapshot)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      document.addWindowController(NSWindowController(window: window))
      let gate = WorkspaceDocumentCloseCoordinator()
      gate.attach(to: window)
      let closed = AsyncStream<Void>.makeStream()
      let closeObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: window, queue: .main
      ) { _ in
        closed.continuation.yield(())
        closed.continuation.finish()
      }
      defer {
        NotificationCenter.default.removeObserver(closeObserver)
        document.release.signal()
        gate.detach()
        document.close()
      }
      var started = document.started.stream.makeAsyncIterator()
      for index in 0..<saveCount {
        source.stateService.workspaceDefinition.displayName = "Confirmed save \(index)"
        let expected = try await source.snapshot(
          contentType: WorkspaceDocument.readableContentTypes[0])
        document.snapshot.withLock { $0 = expected }
        let completion = AsyncStream<Bool>.makeStream()
        document.performActivity(withSynchronousWaiting: false) { finishActivity in
          document.continueActivity {
            document.save(
              to: root, ofType: WorkspaceDocument.readableContentTypes[0].identifier,
              for: index == 0 ? .saveAsOperation : .saveOperation
            ) { error in
              completion.continuation.yield(error == nil)
              completion.continuation.finish()
              finishActivity()
            }
          }
        }
        _ = await started.next()
        if index == saveCount - 1 {
          let button = try #require(window.standardWindowButton(.closeButton))
          NSApplication.shared.sendAction(
            try #require(button.action), to: button.target, from: button)
        }
        // This main-thread continuation is intentionally required by the writer.
        DispatchQueue.main.async { document.release.signal() }
        var saved = completion.stream.makeAsyncIterator()
        #expect(await saved.next() == true)
        #expect(!document.timedOut.withLock { $0 })
        #expect(try WorkspaceBundleReaderV4(at: root).read() == expected)
      }
      var didClose = closed.stream.makeAsyncIterator()
      #expect(await didClose.next() != nil)
    }

    @Test func failedDelayedSavePreservesDiskAndUnsavedContent() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("ldtxworkspace")
      defer { try? FileManager.default.removeItem(at: root) }
      let source = WorkspaceDocument()
      let baseline = try await source.snapshot(
        contentType: WorkspaceDocument.readableContentTypes[0])
      try WorkspaceBundleWriterV4().write(baseline, to: root)
      source.stateService.workspaceDefinition.displayName = "Unsaved after failure"
      let changed = try await source.snapshot(
        contentType: WorkspaceDocument.readableContentTypes[0])
      let document = SaveBridgeDocument(snapshot: changed, fail: true)
      document.fileURL = root
      document.fileType = WorkspaceDocument.readableContentTypes[0].identifier
      document.updateChangeCount(.changeDone)
      defer { document.close() }
      let completion = AsyncStream<Bool>.makeStream()
      document.save(to: root, ofType: document.fileType!, for: .saveOperation) { error in
        completion.continuation.yield(error != nil)
        completion.continuation.finish()
      }
      var started = document.started.stream.makeAsyncIterator()
      _ = await started.next()
      document.release.signal()
      var failed = completion.stream.makeAsyncIterator()
      #expect(await failed.next() == true)
      #expect(document.isDocumentEdited)
      #expect(!document.timedOut.withLock { $0 })
      #expect(try WorkspaceBundleReaderV4(at: root).read() == baseline)
      #expect(source.workspaceSnapshot == changed)
      #expect(source.stateService.editingWorkspace == changed)
    }
  }
}

@MainActor
private final class CloseTarget: NSObject {
  var calls = 0
  @objc func close(_ sender: Any?) { calls += 1 }
}

/// Models the SwiftUI bridge's worker -> MainActor completion dependency without
/// an indefinitely hung test process. AppKit still performs the actual safe save.
@MainActor
private final class SaveBridgeDocument: NSDocument {
  override nonisolated class var writableTypes: [String] {
    [WorkspaceDocument.readableContentTypes[0].identifier]
  }
  override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
    Self.writableTypes
  }
  nonisolated let snapshot: Mutex<WorkspaceV4Bundle>
  nonisolated let fail: Bool
  nonisolated let release = DispatchSemaphore(value: 0)
  nonisolated let timedOut = Mutex(false)
  nonisolated let started = AsyncStream<Void>.makeStream()

  init(snapshot: WorkspaceV4Bundle, fail: Bool = false) {
    self.snapshot = Mutex(snapshot)
    self.fail = fail
    super.init()
  }

  override nonisolated func canAsynchronouslyWrite(
    to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType
  ) -> Bool { true }

  override nonisolated func write(to url: URL, ofType typeName: String) throws {
    let captured = snapshot.withLock { $0 }
    unblockUserInteraction()
    DispatchQueue.main.async { [self] in
      started.continuation.yield(())
    }
    if release.wait(timeout: .now() + 5) == .timedOut {
      timedOut.withLock { $0 = true }
    }
    if fail { throw CocoaError(.fileWriteNoPermission) }
    try WorkspaceBundleWriterV4().write(captured, to: url)
  }
}
