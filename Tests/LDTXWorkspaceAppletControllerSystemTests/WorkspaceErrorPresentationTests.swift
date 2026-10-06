// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXProgramRuntime
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletInterface
import LDTXWorkspaceAppletUI
import Testing

@Suite(.serialized)
@MainActor
struct WorkspaceErrorPresentationIntegrationTestSuite {
  private func makeController() -> (WorkspaceDocument, WorkspaceWindowController, NSWindow) {
    _ = NSApplication.shared
    let document = WorkspaceDocument()
    let controller = WorkspaceWindowController(
      storeService: document.storeService, persistenceCoordinator: document.persistenceCoordinator,
      appletData: WorkspaceAppletData(), documentReference: DocumentReference(document))
    let window = controller.window!
    window.orderFront(nil)
    return (document, controller, window)
  }

  private func waitForSheet(on window: NSWindow, excluding previous: NSWindow? = nil) async throws
    -> NSWindow
  {
    for _ in 0..<200 {
      if let sheet = window.attachedSheet, sheet !== previous { return sheet }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw NSError(
      domain: "WorkspaceErrorTest", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for error sheet."])
  }

  private func dismiss(_ sheet: NSWindow) {
    sheet.sheetParent?.endSheet(sheet)
  }

  private func displayedText(in view: NSView?) -> String {
    guard let view else { return "" }
    return ((view as? NSTextField)?.stringValue ?? "") + "\n"
      + view.subviews.map { displayedText(in: $0) }.joined(separator: "\n")
  }

  @Test func errorsQueueOnEditingSheetAndStopAfterShutdown() async throws {
    let (document, controller, window) = makeController()
    let editor = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.titled], backing: .buffered, defer: false)
    editor.isReleasedWhenClosed = false
    window.beginSheet(editor, completionHandler: { _ in })
    defer {
      if let sheet = editor.attachedSheet { dismiss(sheet) }
      dismiss(editor)
      window.close()
      document.close()
    }
    let error = NSError(
      domain: "test", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "Edit failed.",
        NSLocalizedFailureReasonErrorKey: "A retained failure reason.",
        NSLocalizedRecoverySuggestionErrorKey: "Retry the edit.",
      ])
    document.storeService.reportError(error)
    let first = try await waitForSheet(on: editor)
    #expect(first.sheetParent === editor)
    let text = displayedText(in: first.contentView)
    #expect(text.contains("Edit failed."))
    #expect(text.contains("A retained failure reason."))
    #expect(text.contains("Retry the edit."))
    document.storeService.reportError(NSError(domain: "test", code: 2))
    #expect(editor.attachedSheet === first)
    dismiss(first)
    let second = try await waitForSheet(on: editor, excluding: first)
    #expect(second !== first)
    await controller.shutdown()
    dismiss(second)
    document.storeService.reportError(error)
    controller.reportError(error)
    try await Task.sleep(for: .milliseconds(100))
    #expect(editor.attachedSheet == nil)
  }

  @Test func runtimeFailuresAreScopedDeduplicatedAndCanRecur() async throws {
    let (firstDocument, first, firstWindow) = makeController()
    let (secondDocument, second, secondWindow) = makeController()
    defer {
      if let sheet = firstWindow.attachedSheet { dismiss(sheet) }
      if let sheet = secondWindow.attachedSheet { dismiss(sheet) }
      firstWindow.close()
      secondWindow.close()
      firstDocument.close()
      secondDocument.close()
    }
    let engineID = first.windowRuntime.captureSessionCoordinator.audioEngine.statusIdentifier
    NotificationCenter.default.post(
      name: WorkspaceAudioEngine.statusDidChange, object: engineID,
      userInfo: ["failures": ["Monitor": Int32(-50)]])
    let initial = try await waitForSheet(on: firstWindow)
    #expect(secondWindow.attachedSheet == nil)
    first.updateMonitorFailure(-50)
    dismiss(initial)
    try await Task.sleep(for: .milliseconds(100))
    #expect(firstWindow.attachedSheet == nil)
    first.updateMonitorFailure(nil)
    first.updateMonitorFailure(-50)
    let recurrence = try await waitForSheet(on: firstWindow)
    dismiss(recurrence)
    try await Task.sleep(for: .milliseconds(100))
    first.updateCaptureFailures(["camera-a", "camera-b"])
    let capture = try await waitForSheet(on: firstWindow)
    first.updateCaptureFailures(["camera-a", "camera-b"])
    dismiss(capture)
    try await Task.sleep(for: .milliseconds(100))
    #expect(firstWindow.attachedSheet == nil)
    first.updateCaptureFailures([])
    first.updateCaptureFailures(["camera-a"])
    let retry = try await waitForSheet(on: firstWindow)
    dismiss(retry)
    await first.shutdown()
    await second.shutdown()
  }

  @Test func closingWindowDiscardsQueuedAndLateErrors() async throws {
    let (document, controller, window) = makeController()
    defer {
      window.close()
      document.close()
    }
    controller.reportError(NSError(domain: "test", code: 1))
    let sheet = try await waitForSheet(on: window)
    controller.reportError(NSError(domain: "test", code: 2))
    window.close()
    if sheet.sheetParent != nil { dismiss(sheet) }
    controller.updateMonitorFailure(-50)
    controller.updateCaptureFailures(["camera"])
    controller.reportError(NSError(domain: "test", code: 3))
    try await Task.sleep(for: .milliseconds(100))
    #expect(window.attachedSheet == nil)
    await controller.shutdown()
  }
}
