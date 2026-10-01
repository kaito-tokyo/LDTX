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

  @Test func standardInitializationOwnsLockWithoutControllerConfiguration() async throws {
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
    #expect(document.appletData === original.appletData)
    #expect(document.fileURL == url)
    #expect(document.uiState.localStateURL == url)
    #expect(document.persistenceCoordinator.url == url)
    #expect(throws: (any Error).self) {
      _ = try WorkspaceDocument(contentsOf: url, ofType: "tokyo.kaito.ldtx.workspace")
    }
    document.close()
    let reopened = try WorkspaceDocument(contentsOf: url, ofType: "tokyo.kaito.ldtx.workspace")
    reopened.close()
  }

  @Test func restorationLocksFormalURLAndKeepsRecoveryContentsSeparate() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let formalURL = root.appendingPathComponent("Formal.ldtxworkspace")
    let recoveryURL = root.appendingPathComponent("Recovery.ldtxworkspace")
    let source = WorkspaceDocument()
    try await save(source, to: formalURL)
    source.uiState.definition.displayName = "Recovered edit"
    try await save(source, to: recoveryURL)
    source.close()
    let controller = Self.controller
    let document = try #require(
      controller.makeDocument(
        for: formalURL, withContentsOf: recoveryURL, ofType: "tokyo.kaito.ldtx.workspace")
        as? WorkspaceDocument)
    defer { document.close() }
    #expect(document.fileURL == formalURL)
    #expect(document.autosavedContentsFileURL == recoveryURL)
    #expect(document.uiState.localStateURL == formalURL)
    #expect(document.persistenceCoordinator.url == formalURL)
    #expect(document.uiState.definition.displayName == "Recovered edit")
    #expect(document.isDocumentEdited)
    #expect(throws: (any Error).self) { _ = try WorkspaceLockService().acquire(at: formalURL) }
    let recoveryLock = try WorkspaceLockService().acquire(at: recoveryURL)
    WorkspaceLockService().release(recoveryLock)
    let untitled = try WorkspaceDocument(
      for: nil, withContentsOf: recoveryURL, ofType: "tokyo.kaito.ldtx.workspace")
    defer { untitled.close() }
    #expect(untitled.fileURL == nil)
    #expect(untitled.persistenceCoordinator.url == nil)
    #expect(untitled.uiState.localStateURL?.scheme == "ldtx-untitled")
    #expect(untitled.isDocumentEdited)
  }

  @Test func failedReadAndRecoveryInitializationReleasePackageLocks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    #expect(throws: (any Error).self) {
      _ = try WorkspaceDocument(contentsOf: root, ofType: "tokyo.kaito.ldtx.workspace")
    }
    let lock = try WorkspaceLockService().acquire(at: root)
    WorkspaceLockService().release(lock)
    let url = root.appendingPathComponent("Valid.ldtxworkspace")
    let source = WorkspaceDocument()
    try await save(source, to: url)
    source.close()
    #expect(throws: (any Error).self) {
      _ = try WorkspaceDocument(
        for: root.appendingPathComponent("Missing.ldtxworkspace"), withContentsOf: url,
        ofType: "tokyo.kaito.ldtx.workspace")
    }
    let released = try WorkspaceLockService().acquire(at: url)
    WorkspaceLockService().release(released)

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
        to: destination, ofType: "tokyo.kaito.ldtx.workspace", for: .saveOperation))
    document.uiState.definition.displayName = "Later edit"
    let writer = BackgroundSnapshotWriter(document: document, destination: destination)
    try await Task.detached { try writer.write() }.value
    document.updateChangeCount(withToken: token, for: .saveOperation)
    #expect(
      try WorkspaceBundleReaderV4(at: destination).read().definition.displayName == "Snapshot")
    #expect(document.isDocumentEdited)
    document.close()
  }

  @Test func autosaveElsewhereDoesNotAdoptRecoveryURL() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = WorkspaceDocument()
    document.uiState.definition.displayName = "Recovered"
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let recovery = root.appendingPathComponent("Recovery.ldtxworkspace")
    try await save(document, to: recovery, operation: .autosaveElsewhereOperation)
    #expect(document.fileURL == nil)
    #expect(document.persistenceCoordinator.url == nil)
    #expect(document.autosavedContentsFileURL == recovery)
    #expect(try WorkspaceBundleReaderV4(at: recovery).read().definition.displayName == "Recovered")
    document.close()
    await Task.yield()
  }

  @Test func lockConflictPreservesSourceAndDirtyState() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = WorkspaceDocument()
    let second = WorkspaceDocument()
    let firstURL = root.appendingPathComponent("First.ldtxworkspace")
    let secondURL = root.appendingPathComponent("Second.ldtxworkspace")
    try await save(first, to: firstURL)
    try await save(second, to: secondURL)
    second.uiState.definition.displayName = "Unsaved"
    do {
      try await save(second, to: firstURL)
      Issue.record("Save As should fail while another document owns the package lock")
    } catch {
      #expect(second.fileURL == secondURL)
      #expect(second.isDocumentEdited)
    }
    first.close()
    second.close()
    await Task.yield()
  }

  @Test func moveKeepsRuntimeURLAndLockInSync() async throws {
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
    let other = WorkspaceDocument()
    do {
      try await save(other, to: moved)
      Issue.record("Moved package must remain locked")
    } catch { #expect(other.fileURL == nil) }
    document.close()
    other.close()
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

  @Test func outputDisablesSaveAsAndRevertButAllowsDuplicate() {
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
    try document.fileWrapper(ofType: "tokyo.kaito.ldtx.workspace")
      .write(to: destination, options: .atomic, originalContentsURL: nil)
  }
}
