// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import LDTXAppletSupport
import LDTXBackgroundSegmentation
import LDTXProtos
import LDTXTaskQueue
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletService
@testable import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import SwiftProtobuf
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1005: reopen-and-move", .serialized)
  @MainActor
  struct UCT1005WorkspaceDocumentIntegrationTestSuite {
    private static var controller: NSDocumentController {
      UIComponentTestEnvironment.documentController
    }
    init() { _ = Self.controller }

    @Test("UCT-1005.1: Opening the same URL reuses the registered Document")
    func standardControllerReusesDocumentWithoutAnExclusiveLock() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("Workspace.ldtxworkspace")
      let original = WorkspaceDocument()
      try await saveWorkspaceDocument(original, to: url)
      original.close()
      let controller = Self.controller
      let document = try #require(
        controller.makeDocument(withContentsOf: url, ofType: "tokyo.kaito.ldtx.workspace")
          as? WorkspaceDocument)
      controller.addDocument(document)
      defer { document.close() }
      #expect(document.fileURL == url)
      #expect(document.storeService.localStateURL == url)
      #expect(document.persistenceCoordinator.url == url)
      let independentlyOpened = try WorkspaceDocument(
        contentsOf: url, ofType: "tokyo.kaito.ldtx.workspace")
      independentlyOpened.close()
      let reopened: NSDocument = try await withCheckedThrowingContinuation { continuation in
        controller.openDocument(withContentsOf: url, display: false) {
          document, alreadyOpen, error in
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

    @Test("UCT-1005.2: Restoration requires an existing Workspace package URL")
    func restorationUsesFormalPackageAndRejectsMissingOrNilURL() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let formal = root.appendingPathComponent("Formal.ldtxworkspace")
      let recovery = root.appendingPathComponent("LegacyRecovery.ldtxworkspace")
      let source = WorkspaceDocument()
      try await saveWorkspaceDocument(source, to: formal)
      source.close()
      var legacy = try WorkspaceBundleReaderV4(at: formal).read()
      legacy.definition.displayName = "Uncommitted legacy edit"
      try WorkspaceDocumentPackage.write(legacy, to: recovery, createsPackage: true)
      let document = try WorkspaceDocument(
        for: formal, withContentsOf: recovery,
        ofType: "tokyo.kaito.ldtx.workspace")
      defer { document.close() }
      #expect(document.fileURL == formal)
      #expect(document.storeService.definition.displayName == "Formal")
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

    @Test("UCT-1005.3: Workspace owns its Window Controller and uses standard restoration")
    func ownsControllerAndUsesStandardRestoration() async throws {
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

    @Test("UCT-1005.4: Moving a presented Workspace preserves resources and rebinds local state")
    func presentedMoveRebindsStateAndPreservesResources() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let document = WorkspaceDocument()
      defer { document.close() }
      let original = root.appendingPathComponent("Original.ldtxworkspace")
      let moved = root.appendingPathComponent("Renamed.ldtxworkspace")
      try await saveWorkspaceDocument(document, to: original)
      let resource = Data("Preserved resource".utf8)
      try resource.write(to: original.appendingPathComponent("resource.bin"))
      try FileManager.default.moveItem(at: original, to: moved)
      document.presentedItemDidMove(to: moved)
      for _ in 0..<100 where document.storeService.localStateURL != moved {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(document.fileURL == moved)
      #expect(document.storeService.localStateURL == moved)
      #expect(document.persistenceCoordinator.url == moved)
      let other = try WorkspaceDocument(contentsOf: moved, ofType: "tokyo.kaito.ldtx.workspace")
      other.close()
      document.storeService.definition.displayName = "After move"
      try await saveWorkspaceDocument(document, to: moved, operation: .saveOperation)
      #expect(!document.isDocumentEdited)
      #expect(try Data(contentsOf: moved.appendingPathComponent("resource.bin")) == resource)
      #expect(try WorkspaceBundleReaderV4(at: moved).read().definition.displayName == "After move")
    }

    @Test("UCT-1005.5: Moving a Workspace synchronizes its runtime URL")
    func moveKeepsRuntimeURLInSync() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let document = WorkspaceDocument()
      let original = root.appendingPathComponent("Original.ldtxworkspace")
      let moved = root.appendingPathComponent("Moved.ldtxworkspace")
      try await saveWorkspaceDocument(document, to: original)
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        document.move(to: moved) { error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
      }
      #expect(document.fileURL == moved)
      #expect(document.persistenceCoordinator.url == moved)
      #expect(!FileManager.default.fileExists(atPath: original.path))
      document.close()
    }

  }
}
