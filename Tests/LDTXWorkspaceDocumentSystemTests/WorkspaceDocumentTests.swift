// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletService
import LDTXWorkspaceBundleFormat
import Testing

@MainActor
private final class WorkspaceInitializingDocumentController: NSDocumentController {
  override func documentClass(forType typeName: String) -> AnyClass? { WorkspaceDocument.self }
}

@Suite(.serialized)
@MainActor
struct WorkspaceDocumentSystemTestSuite {
  private static let controller = WorkspaceInitializingDocumentController()

  init() { _ = Self.controller }

  @Test func standardControllerReusesDocumentWithoutAnExclusiveLock() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Workspace.ldtxworkspace")
    let original = WorkspaceDocument()
    try await save(original, to: url)
    original.close()
    let controller = Self.controller
    let document = try #require(
      controller.makeDocument(withContentsOf: url, ofType: "tokyo.kaito.ldtx.workspace")
        as? WorkspaceDocument)
    controller.addDocument(document)
    defer { document.close() }
    #expect(document.fileURL == url)
    #expect(document.uiState.localStateURL == url)
    #expect(document.persistenceCoordinator.url == url)
    let independentlyOpened = try WorkspaceDocument(
      contentsOf: url, ofType: "tokyo.kaito.ldtx.workspace")
    independentlyOpened.close()
    let reopened: NSDocument = try await withCheckedThrowingContinuation { continuation in
      controller.openDocument(withContentsOf: url, display: false) { document, alreadyOpen, error in
        #expect(alreadyOpen)
        if let error {
          continuation.resume(throwing: error)
        } else if let document {
          continuation.resume(returning: document)
        } else {
          continuation.resume(throwing: CocoaError(.fileReadUnknown))
        }
      }
    }
    #expect(reopened === document)
    #expect(
      !FileManager.default.fileExists(
        atPath:
          root.appendingPathComponent(".Workspace.ldtxworkspace.LDTX.lock").path))
  }

  @Test func restorationUsesFormalPackageAndRejectsMissingOrNilURL() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let formal = root.appendingPathComponent("Formal.ldtxworkspace")
    let recovery = root.appendingPathComponent("LegacyRecovery.ldtxworkspace")
    let source = WorkspaceDocument()
    try await save(source, to: formal)
    source.close()
    var legacy = try WorkspaceBundleReaderV4(at: formal).read()
    legacy.definition.displayName = "Uncommitted legacy edit"
    try WorkspaceDocumentPackage.write(legacy, to: recovery, createsPackage: true)
    let document = try WorkspaceDocument(
      for: formal, withContentsOf: recovery,
      ofType: "tokyo.kaito.ldtx.workspace")
    defer { document.close() }
    #expect(document.fileURL == formal)
    #expect(document.uiState.definition.displayName == "Formal")
    #expect(!document.isDocumentEdited)
    #expect(document.autosavedContentsFileURL == nil)
    #expect(throws: (any Error).self) {
      _ = try WorkspaceDocument(
        for: nil, withContentsOf: recovery, ofType: "tokyo.kaito.ldtx.workspace")
    }
    #expect(throws: (any Error).self) {
      _ = try WorkspaceDocument(
        for: root.appendingPathComponent("Missing.ldtxworkspace"),
        withContentsOf: recovery, ofType: "tokyo.kaito.ldtx.workspace")
    }
    let corrupt = root.appendingPathComponent("Corrupt.ldtxworkspace")
    try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
    #expect(throws: (any Error).self) {
      _ = try WorkspaceDocument(
        for: corrupt, withContentsOf: recovery, ofType: "tokyo.kaito.ldtx.workspace")
    }
    #expect(
      try WorkspaceBundleReaderV4(at: recovery).read().definition.displayName
        == legacy.definition.displayName)
  }

  @Test func dockBadgeFollowsRegisteredDocuments() {
    let dockTile = NSApplication.shared.dockTile
    let originalBadge = dockTile.badgeLabel
    let controller = NSDocumentController.shared
    let first = WorkspaceDocument()
    let second = WorkspaceDocument()
    controller.addDocument(first)
    controller.addDocument(second)
    defer {
      first.close()
      second.close()
      dockTile.badgeLabel = originalBadge
    }
    first.uiState.isOutputActive = true
    first.uiState.isOutputActive = true
    second.uiState.isOutputActive = true
    #expect(dockTile.badgeLabel == "REC")
    first.uiState.isOutputActive = false
    #expect(dockTile.badgeLabel == "REC")
    second.uiState.isOutputActive = false
    #expect(dockTile.badgeLabel == nil)
    first.uiState.isOutputActive = true
    second.uiState.isOutputActive = true
    first.close()
    #expect(dockTile.badgeLabel == "REC")
    second.close()
    #expect(dockTile.badgeLabel == nil)
    #expect(!controller.documents.contains { $0 === first || $0 === second })
  }

  private func save(
    _ document: WorkspaceDocument, to url: URL,
    operation: NSDocument.SaveOperationType = .saveAsOperation
  ) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      document.save(to: url, ofType: "tokyo.kaito.ldtx.workspace", for: operation) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  @Test func newWorkspacePreservesInitialContentSize() async throws {
    _ = NSApplication.shared
    let frameKey = "NSWindow Frame WorkspaceV4.AppKit.v1"
    let savedFrame = UserDefaults.standard.object(forKey: frameKey)
    UserDefaults.standard.removeObject(forKey: frameKey)
    defer {
      if let savedFrame {
        UserDefaults.standard.set(savedFrame, forKey: frameKey)
      } else {
        UserDefaults.standard.removeObject(forKey: frameKey)
      }
    }
    let document = WorkspaceDocument()
    document.makeWindowControllers()
    let window = try #require(document.windowControllers.first?.window)
    let contentSize = window.contentRect(forFrameRect: window.frame).size
    #expect(contentSize.width >= 1062)
    #expect(contentSize.height >= 700)
    await document.shutdown()
    document.close()
  }

  @Test func ownsControllerAndUsesStandardRestoration() async throws {
    _ = NSApplication.shared
    let document = WorkspaceDocument()
    let controller = NSDocumentController.shared
    controller.addDocument(document)
    document.makeWindowControllers()
    let windowController = try #require(document.windowControllers.first)
    #expect(document.windowControllers.count == 1)
    #expect(windowController.document === document)
    let window = try #require(windowController.window)
    #expect(window.restorationClass as? NSDocumentController.Type != nil)
    document.makeWindowControllers()
    #expect(document.windowControllers.count == 1)
    await document.shutdown()
    document.close()
    #expect(!controller.documents.contains { $0 === document })
  }

  @Test func firstSaveNamesUntitledWorkspaceAndLaterSaveAsIsRejected() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = WorkspaceDocument()
    defer { document.close() }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let first = root.appendingPathComponent("Show.ldtxworkspace")
    try await save(document, to: first)
    #expect(document.uiState.definition.displayName == "Show")
    #expect(try WorkspaceBundleReaderV4(at: first).read().definition.displayName == "Show")
    #expect(!document.isDocumentEdited)
    let next = root.appendingPathComponent("Another.ldtxworkspace")
    do {
      try await save(document, to: next)
      Issue.record("Expected Save As rejection")
    } catch {}
    #expect(document.fileURL == first)
    #expect(!FileManager.default.fileExists(atPath: next.path))
    #expect(document.uiState.definition.displayName == "Show")
    document.close()
    let reopened = try WorkspaceDocument(contentsOf: first, ofType: "tokyo.kaito.ldtx.workspace")
    defer { reopened.close() }
    #expect(reopened.uiState.definition.displayName == "Show")
  }

  @Test func firstSavePreservesExplicitWorkspaceName() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = WorkspaceDocument()
    defer { document.close() }
    document.uiState.definition.displayName = "Custom"
    let destination = root.appendingPathComponent("Show.ldtxworkspace")
    try await save(document, to: destination)
    #expect(document.uiState.definition.displayName == "Custom")
    #expect(try WorkspaceBundleReaderV4(at: destination).read().definition.displayName == "Custom")
  }

  @Test func tracksChangesSynchronouslyAndUsesAppKitSaveState() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = WorkspaceDocument()
    let destination = root.appendingPathComponent("Saved.ldtxworkspace")
    #expect(document.fileURL == nil)
    document.uiState.definition.displayName = "Saved"
    #expect(document.isDocumentEdited)
    try await save(document, to: destination)
    #expect(!document.isDocumentEdited)
    #expect(document.fileURL == destination)
    #expect(document.persistenceCoordinator.url == destination)
    let saved = try WorkspaceBundleReaderV4(at: destination).read()
    #expect(saved.definitionExternalID?.split(separator: "-")[2].first == "7")
    #expect(saved.preferencesExternalID?.split(separator: "-")[2].first == "7")
    #expect(try WorkspaceBundleReaderV4(at: destination).read().definition.displayName == "Saved")
    document.close()
    await Task.yield()
  }

  @Test func editsBeforeQueuedSaveStartsAreIncluded() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("Snapshot.ldtxworkspace")
    let document = WorkspaceDocument()
    document.uiState.definition.displayName = "Snapshot"
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      document.save(to: destination, ofType: "tokyo.kaito.ldtx.workspace", for: .saveAsOperation) {
        error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
      document.uiState.definition.displayName = "Later edit"
    }
    #expect(
      try WorkspaceBundleReaderV4(at: destination).read().definition.displayName == "Later edit")
    #expect(document.uiState.definition.displayName == "Later edit")
    #expect(!document.isDocumentEdited)
    document.close()
  }

  @Test func backgroundSnapshotDoesNotIncludeLaterEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("Snapshot.ldtxworkspace")
    let document = WorkspaceDocument()
    document.uiState.definition.displayName = "Snapshot"
    let token = document.changeCountToken(for: .saveOperation)
    #expect(
      document.canAsynchronouslyWrite(
        to: destination, ofType: "tokyo.kaito.ldtx.workspace", for: .saveAsOperation))
    document.uiState.definition.displayName = "Later edit"
    let writer = BackgroundSnapshotWriter(document: document, destination: destination)
    try await Task.detached { try writer.write() }.value
    document.updateChangeCount(withToken: token, for: .saveOperation)
    #expect(
      try WorkspaceBundleReaderV4(at: destination).read().definition.displayName == "Snapshot")
    #expect(document.isDocumentEdited)
    document.close()
  }

  @Test func autosaveOperationsAreDisabledAndRejected() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = WorkspaceDocument()
    defer { document.close() }
    let url = root.appendingPathComponent("Workspace.ldtxworkspace")
    try await save(document, to: url)
    let definition = try Data(contentsOf: url.appendingPathComponent("definition.pb"))
    let preferences = try Data(contentsOf: url.appendingPathComponent("preferences.pb"))
    document.uiState.definition.displayName = "Pending"
    document.uiState.preferences.monitorVolume = -6
    #expect(!WorkspaceDocument.autosavesInPlace)
    #expect(!WorkspaceDocument.preservesVersions)
    #expect(document.autosavingFileType == nil)
    for operation in [
      NSDocument.SaveOperationType.autosaveInPlaceOperation,
      .autosaveElsewhereOperation, .autosaveAsOperation,
    ] {
      do {
        try await save(document, to: url, operation: operation)
        Issue.record("Autosaving must be rejected")
      } catch {}
    }
    try await document.autosave(withImplicitCancellability: false)
    #expect(try Data(contentsOf: url.appendingPathComponent("definition.pb")) == definition)
    #expect(try Data(contentsOf: url.appendingPathComponent("preferences.pb")) == preferences)
    #expect(document.isDocumentEdited)
    #expect(document.autosavedContentsFileURL == nil)
  }

  @Test func creationShowsWindowsOnlyAfterSuccessfulSaveAndClosesFailures() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = WorkspaceDocument()
    Self.controller.addDocument(document)
    #expect(document.windowControllers.isEmpty)
    let url = root.appendingPathComponent("New.ldtxworkspace")
    try await save(document, to: url)
    #expect(document.windowControllers.isEmpty)
    document.finishCreation(success: true)
    #expect(document.windowControllers.count == 1)
    #expect(document.windowControllers.first?.window?.isVisible == true)
    await document.shutdown()
    document.close()
    let canceled = WorkspaceDocument()
    Self.controller.addDocument(canceled)
    canceled.finishCreation(success: false)
    #expect(!Self.controller.documents.contains { $0 === canceled })
    let failed = WorkspaceDocument()
    Self.controller.addDocument(failed)
    let partial = root.appendingPathComponent("Partial.ldtxworkspace")
    try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: partial.appendingPathComponent("preferences.pb"),
      withIntermediateDirectories: false)
    do {
      try await save(failed, to: partial)
      Issue.record("Expected first-save failure")
    } catch {}
    failed.finishCreation(success: false)
    #expect(!Self.controller.documents.contains { $0 === failed })
    #expect(
      FileManager.default.fileExists(atPath: partial.appendingPathComponent("Info.plist").path))
  }

  @Test func duplicateIsDisabledAndDoesNotCreateAnotherDocument() throws {
    let document = WorkspaceDocument()
    defer { document.close() }
    let documentsBefore = NSDocumentController.shared.documents
    #expect(
      !document.validateUserInterfaceItem(
        NSMenuItem(
          title: "Duplicate", action: #selector(NSDocument.duplicate(_:)), keyEquivalent: "")))
    #expect(NSDocumentController.shared.documents.count == documentsBefore.count)
    #expect(document.fileURL == nil)
  }

  @Test func copyActionsAreDisabledAndSaveFailureKeepsEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = WorkspaceDocument()
    defer { document.close() }
    for action in [
      #selector(NSDocument.saveAs(_:)), #selector(NSDocument.saveTo(_:)),
      #selector(NSDocument.duplicate(_:)),
    ] {
      #expect(
        !document.validateUserInterfaceItem(
          NSMenuItem(title: "", action: action, keyEquivalent: "")))
    }
    let url = root.appendingPathComponent("Workspace.ldtxworkspace")
    try await save(document, to: url)
    document.writeProbe.withLock { $0 = { throw CocoaError(.fileWriteNoPermission) } }
    defer { document.writeProbe.withLock { $0 = nil } }
    document.uiState.definition.displayName = "Pending"
    do {
      try await save(document, to: url, operation: .saveOperation)
      Issue.record("Expected partial save failure")
    } catch {}
    #expect(document.isDocumentEdited)
    #expect(document.uiState.definition.displayName == "Pending")
    document.writeProbe.withLock { $0 = nil }
    try await save(document, to: url, operation: .saveOperation)
    #expect(!document.isDocumentEdited)
    document.uiState.isOutputActive = true
    let fixedDefinition = document.uiState.definition
    document.uiState.definition.displayName = "Rejected during output"
    document.uiState.preferences.monitorVolume = -8
    try await save(document, to: url, operation: .saveOperation)
    let savedOutput = try WorkspaceBundleReaderV4(at: url).read()
    #expect(savedOutput.preferences.monitorVolume == -8)
    #expect(savedOutput.definition == fixedDefinition)
    document.uiState.isOutputActive = false
  }

  @Test func editsCanProceedWhileBackgroundSaveIsPaused() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = WorkspaceDocument()
    defer { document.close() }
    let url = root.appendingPathComponent("Workspace.ldtxworkspace")
    try await save(document, to: url)
    document.uiState.definition.displayName = "Snapshot"
    let gate = DispatchSemaphore(value: 0)
    let handle = BackgroundSnapshotWriter(document: document, destination: url)
    defer { document.writeProbe.withLock { $0 = nil } }
    document.writeProbe.withLock { probe in
      probe = {
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            handle.document.uiState.definition.displayName = "Later edit"
            gate.signal()
          }
        }
        // A bounded wait fails rather than hanging if interaction remains blocked.
        #expect(!Thread.isMainThread)
        #expect(gate.wait(timeout: .now() + 5) == .success)
      }
    }
    try await save(document, to: url, operation: .saveOperation)
    document.writeProbe.withLock { $0 = nil }
    #expect(document.uiState.definition.displayName == "Later edit")
    #expect(try WorkspaceBundleReaderV4(at: url).read().definition.displayName == "Snapshot")
    #expect(document.isDocumentEdited)
  }

  @Test func presentedMoveRebindsStateAndPreservesResources() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = WorkspaceDocument()
    defer { document.close() }
    let original = root.appendingPathComponent("Original.ldtxworkspace")
    let moved = root.appendingPathComponent("Renamed.ldtxworkspace")
    try await save(document, to: original)
    let resource = Data("Preserved resource".utf8)
    try resource.write(to: original.appendingPathComponent("resource.bin"))
    try FileManager.default.moveItem(at: original, to: moved)
    document.presentedItemDidMove(to: moved)
    for _ in 0..<100 where document.uiState.localStateURL != moved {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(document.fileURL == moved)
    #expect(document.uiState.localStateURL == moved)
    #expect(document.persistenceCoordinator.url == moved)
    let other = try WorkspaceDocument(contentsOf: moved, ofType: "tokyo.kaito.ldtx.workspace")
    other.close()
    document.uiState.definition.displayName = "After move"
    try await save(document, to: moved, operation: .saveOperation)
    #expect(!document.isDocumentEdited)
    #expect(try Data(contentsOf: moved.appendingPathComponent("resource.bin")) == resource)
    #expect(try WorkspaceBundleReaderV4(at: moved).read().definition.displayName == "After move")
  }

  @Test func moveKeepsRuntimeURLInSync() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = WorkspaceDocument()
    let original = root.appendingPathComponent("Original.ldtxworkspace")
    let moved = root.appendingPathComponent("Moved.ldtxworkspace")
    try await save(document, to: original)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      document.move(to: moved) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
    #expect(document.fileURL == moved)
    #expect(document.persistenceCoordinator.url == moved)
    #expect(!FileManager.default.fileExists(atPath: original.path))
    document.close()
  }

  @Test func startingOutputDoesNotSavePendingModelEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Output.ldtxworkspace")
    let document = WorkspaceDocument()
    defer { document.close() }
    try await save(document, to: url)
    let definition = try Data(contentsOf: url.appendingPathComponent("definition.pb"))
    let preferences = try Data(contentsOf: url.appendingPathComponent("preferences.pb"))
    document.makeWindowControllers()
    let controller = try #require(document.windowControllers.first as? WorkspaceWindowController)
    document.uiState.definition.displayName = "Pending"
    document.uiState.preferences.monitorVolume = -9
    // No Program/output is enabled, so this exercises the entry without media I/O.
    try await controller.startOutput()
    #expect(document.isDocumentEdited)
    #expect(document.uiState.definition.displayName == "Pending")
    #expect(try Data(contentsOf: url.appendingPathComponent("definition.pb")) == definition)
    #expect(try Data(contentsOf: url.appendingPathComponent("preferences.pb")) == preferences)
    await document.shutdown()
  }

  @Test func standardCloseCancelKeepsEditsAndDiscardWaitsForShutdown() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Close.ldtxworkspace")
    let document = WorkspaceDocument()
    defer { document.close() }
    try await save(document, to: url)
    Self.controller.addDocument(document)
    document.makeWindowControllers()
    let window = try #require(document.windowControllers.first?.window)
    window.orderFront(nil)
    document.uiState.definition.displayName = "Pending"
    let probe = WorkspaceCloseProbe()
    document.canClose(
      withDelegate: probe,
      shouldClose: #selector(WorkspaceCloseProbe.document(_:shouldClose:contextInfo:)),
      contextInfo: nil)
    try await clickCloseSheetButton("Cancel", in: window)
    for _ in 0..<100 where probe.result == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(probe.result == false)
    #expect(document.isDocumentEdited)
    #expect(window.isVisible)
    #expect(Self.controller.documents.contains { $0 === document })
    probe.result = nil
    document.canClose(
      withDelegate: probe,
      shouldClose: #selector(WorkspaceCloseProbe.document(_:shouldClose:contextInfo:)),
      contextInfo: nil)
    try await clickCloseSheetButton("Don’t Save", in: window)
    for _ in 0..<200 where probe.result == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(probe.result == true)
    document.close()
    #expect(!Self.controller.documents.contains { $0 === document })
    #expect(!window.isVisible)
    #expect(try WorkspaceBundleReaderV4(at: url).read().definition.displayName == "Close")
  }

  private func clickCloseSheetButton(_ title: String, in window: NSWindow) async throws {
    func find(_ view: NSView) -> NSButton? {
      if let button = view as? NSButton {
        let normalized = button.title.replacingOccurrences(of: "’", with: "'")
        let expected = title.replacingOccurrences(of: "’", with: "'")
        let japanese = ["Cancel": "キャンセル", "Don’t Save": "保存しない"][title]
        if normalized == expected || button.title == japanese { return button }
      }
      return view.subviews.lazy.compactMap { find($0) }.first
    }
    for _ in 0..<200 {
      if let content = window.attachedSheet?.contentView, let button = find(content) {
        button.performClick(nil)
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CocoaError(.userCancelled)
  }

  @Test func outputFreezesDefinitionButTracksPreferences() {
    let document = WorkspaceDocument()
    let original = document.uiState.definition
    document.uiState.isOutputActive = true
    document.uiState.definition.displayName = "Rejected"
    #expect(document.uiState.definition == original)
    #expect(!document.isDocumentEdited)
    document.uiState.preferences.monitorVolume = -6
    #expect(document.isDocumentEdited)
  }

  @Test func outputDisablesSaveAsAndRevert() {
    let document = WorkspaceDocument()
    document.uiState.isOutputActive = true
    let saveAs = NSMenuItem(
      title: "Save As", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "")
    let revert = NSMenuItem(
      title: "Revert", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
    #expect(!document.validateUserInterfaceItem(saveAs))
    #expect(!document.validateUserInterfaceItem(revert))
  }
}

// This handle exposes only the document's nonisolated, snapshot-based writer.
private struct BackgroundSnapshotWriter: @unchecked Sendable {
  let document: WorkspaceDocument
  let destination: URL
  func write() throws {
    try document.writeSafely(
      to: destination, ofType: "tokyo.kaito.ldtx.workspace", for: .saveAsOperation)
  }
}

@MainActor
private final class WorkspaceCloseProbe: NSObject {
  var result: Bool?
  @objc func document(
    _ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?
  ) {
    result = shouldClose
  }
}
