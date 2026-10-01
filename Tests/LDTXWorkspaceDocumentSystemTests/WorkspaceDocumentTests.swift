// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceBundleFormat
import Testing

@Suite(.serialized)
@MainActor
struct WorkspaceDocumentSystemTestSuite {
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

  @Test func recordingOpenRequiresHostAndRoutesOnce() async {
    let controller = WorkspaceDocumentController()
    let url = URL(fileURLWithPath: "/tmp/Route.LDTXRECORD")
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      controller.openDocument(withContentsOf: url, display: true) { document, alreadyOpen, error in
        #expect(document == nil)
        #expect(!alreadyOpen)
        #expect(error != nil)
        continuation.resume()
      }
    }
    var routedURLs: [URL] = []
    controller.openRecording = { routedURLs.append($0) }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      controller.openDocument(withContentsOf: url, display: true) { document, alreadyOpen, error in
        #expect(document == nil)
        #expect(!alreadyOpen)
        #expect(error == nil)
        continuation.resume()
      }
    }
    #expect(routedURLs == [url])
    #expect(controller.documents.isEmpty)
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
