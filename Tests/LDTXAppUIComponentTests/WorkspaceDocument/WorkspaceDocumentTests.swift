// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProtos
@testable import LDTXWorkspaceAppletController
@testable import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("Workspace DocumentGroup persistence", .serialized)
  @MainActor
  struct WorkspaceDocumentIntegrationTestSuite {
    @Test("Saved documents round-trip all three protobuf documents")
    func roundTrip() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("Workspace.ldtxworkspace")
      let document = WorkspaceDocument()
      document.stateService.workspaceDefinition.displayName = "Main"
      try await saveWorkspaceDocument(document, to: url)
      let reopened = try await loadWorkspaceDocument(at: url)
      #expect(reopened.workspace == document.workspace)
      #expect(reopened.fileURL == url)
      #expect(reopened.stateService.modelURLs.isEmpty)
    }

    @Test("Staged writes do not expose definitions before the formal save completes")
    func stagedWriteKeepsRuntimeDefinition() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("Formal.ldtxworkspace")
      let staged = root.appendingPathComponent("Staging.ldtxworkspace")
      let document = WorkspaceDocument()
      document.stateService.workspaceDefinition.displayName = "Saved"
      try await saveWorkspaceDocument(document, to: url)
      document.stateService.workspaceDefinition.displayName = "Pending"
      let snapshot = try await document.snapshot(
        contentType: WorkspaceDocument.readableContentTypes[0])
      let progress = ProgressManager(totalCount: 1)
      try await document.packageWriter.write(
        snapshot: snapshot, to: staged, previous: nil,
        progress: progress.subprogress(assigningCount: 1))
      await document.acceptPersistedWrite()
      #expect(document.persistenceCoordinator.runtimeWorkspace.definition.displayName == "Saved")
      #expect(document.stateService.workspaceDefinition.displayName == "Pending")
      #expect(try WorkspaceBundleReaderV4(at: url).read().definition.displayName == "Saved")
      try FileManager.default.removeItem(at: url)
      try FileManager.default.moveItem(at: staged, to: url)
      document.stateService.workspaceDefinition.displayName = "Later"
      await document.acceptPersistedWrite()
      #expect(document.persistenceCoordinator.runtimeWorkspace.definition.displayName == "Pending")
      #expect(document.stateService.workspaceDefinition.displayName == "Later")
    }

    @Test("Invalid data fails before creating a destination")
    func invalidDataDoesNotWrite() async throws {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "\(UUID()).ldtxworkspace")
      let document = WorkspaceDocument()
      document.stateService.workspaceDefinition.programs = [.with { $0.internalID = 0 }]
      do {
        try await saveWorkspaceDocument(document, to: url)
        Issue.record("Expected validation error")
      } catch { #expect(error is WorkspaceSaveValidationError) }
      #expect(!FileManager.default.fileExists(atPath: url.path))
      #expect(document.fileURL == nil)
    }

    @Test("Preferences are visible to the runtime before saving")
    func livePreferences() async throws {
      let document = WorkspaceDocument()
      document.stateService.workspacePreferences.landscapeProgramPreferences[7] = .with {
        $0.audioMasterVolumeDecibels.set(num: -50, den: 10)
      }
      #expect(
        document.persistenceCoordinator.runtimeWorkspace.preferences
          == document.stateService.workspacePreferences)
      #expect(
        document.persistenceCoordinator.runtimeWorkspace.definition
          != document.stateService.workspaceDefinition)
    }

    @Test("Snapshots retain edits; invalid ROI fails on save without updating runtime")
    func invalidROIIsValidatedOnSave() async throws {
      let document = WorkspaceDocument()
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: url) }
      try await saveWorkspaceDocument(document, to: url)
      let persisted = document.runtimeWorkspace
      document.stateService.workspaceDefinition.videoComponents = [
        .with { $0.vfxSource = .with {
          $0.internalID = 7; $0.displayName = "Camera"
          $0.deviceWidth = 1920; $0.deviceHeight = 1080
        } }
      ]
      document.stateService.workspaceDefinition.visions = [
        .with { $0.ocrVision = .with {
          $0.internalID = 9; $0.displayName = "OCR"; $0.videoComponentInternalID = 7
        } }
      ]
      document.stateService.workspaceDefinition.visions[0].ocrVision.regionOfInterest.x
        .set(num: 2, den: 1)
      let snapshot = try await document.snapshot(contentType: WorkspaceDocument.readableContentTypes[0])
      #expect(snapshot.workspace.definition == document.stateService.workspaceDefinition)
      await #expect(throws: (any Error).self) { try await saveWorkspaceDocument(document, to: url) }
      #expect(document.runtimeWorkspace == persisted)
      #expect(document.stateService.workspaceDefinition.visions[0].ocrVision.regionOfInterest.x.num == 2)
    }


    @Test("A reload merges current edits while adopting the persisted runtime definition")
    func reloadPreservesCurrentEdits() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("Workspace.ldtxworkspace")
      let document = WorkspaceDocument()
      try await saveWorkspaceDocument(document, to: url)
      let progress = ProgressManager(totalCount: 1)
      let previous = try await WorkspaceDocument.Reader().read(
        from: url, progress: progress.subprogress(assigningCount: 1))
      var external = previous.workspace
      external.definition.displayName = "External"
      try WorkspaceDocumentPackage.write(external, to: url)
      let readProgress = ProgressManager(totalCount: 1)
      let incoming = try await WorkspaceDocument.Reader().read(
        from: url, progress: readProgress.subprogress(assigningCount: 1))
      document.stateService.workspaceDefinition.displayName = "Local"
      try await document.apply(snapshot: incoming, previous: previous)
      #expect(document.stateService.workspaceDefinition.displayName == "Local")
      #expect(document.persistenceCoordinator.runtimeWorkspace.definition.displayName == "External")
    }

    @Test("Missing or malformed packages are rejected")
    func corruptRead() async throws {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let progress = ProgressManager(totalCount: 1)
      await #expect(throws: (any Error).self) {
        try await WorkspaceDocument.Reader().read(
          from: url, progress: progress.subprogress(assigningCount: 1))
      }
    }

    @Test("Model imports preserve newer selections and prior embedded revisions")
    func modelSelectionDuringSave() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("Models.ldtxworkspace")
      let first = root.appendingPathComponent("First.mlmodel")
      let second = root.appendingPathComponent("Second.mlmodel")
      try Data([1]).write(to: first)
      try Data([2]).write(to: second)
      let document = WorkspaceDocument()
      document.stateService.workspaceDefinition.videoComponents = [
        .with {
          $0.vfxSource = .with {
            $0.internalID = 7
            $0.displayName = "Camera"
            $0.deviceWidth = 1920
            $0.deviceHeight = 1080
          }
        }
      ]
      document.stateService.workspaceDefinition.visions = [
        .with {
          $0.ldtxSceneDetectorVision = .with {
            $0.internalID = 5
            $0.displayName = "Classifier"
            $0.videoComponentInternalID = 7
          }
        }
      ]
      document.stateService.modelURLs[5] = first
      let snapshot = try await document.snapshot(
        contentType: WorkspaceDocument.readableContentTypes[0])
      document.stateService.modelURLs[5] = second
      let progress = ProgressManager(totalCount: 1)
      try await document.packageWriter.write(
        snapshot: snapshot, to: url, previous: nil,
        progress: progress.subprogress(assigningCount: 1))
      document.adoptDocumentURL(url)
      await document.acceptPersistedWrite()
      let revision = document.stateService.workspaceDefinition.visions[0].ldtxSceneDetectorVision
        .modelRevision
      #expect(revision > 0)
      #expect(document.stateService.modelURLs[5] == .some(second))
      let firstURL = url.appendingPathComponent("VisionModels/5/\(revision)/First.mlmodel")
      #expect(try Data(contentsOf: firstURL) == Data([1]))
      try await saveWorkspaceDocument(document, to: url)
      #expect(!document.stateService.modelURLs.keys.contains(5))
      #expect(try Data(contentsOf: firstURL) == Data([1]))
      let missing = root.appendingPathComponent("Missing.mlmodel")
      document.stateService.modelURLs[5] = missing
      let saved = document.persistenceCoordinator.runtimeWorkspace
      do {
        try await saveWorkspaceDocument(document, to: url)
        Issue.record("Expected read failure")
      } catch {}
      #expect(document.persistenceCoordinator.runtimeWorkspace == saved)
      #expect(document.stateService.modelURLs[5] == .some(missing))
    }

    @Test("External reload is rejected while output is active")
    func outputRejectsReload() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("Output.ldtxworkspace")
      let document = WorkspaceDocument()
      try await saveWorkspaceDocument(document, to: url)
      let progress = ProgressManager(totalCount: 1)
      let snapshot = try await WorkspaceDocument.Reader().read(
        from: url, progress: progress.subprogress(assigningCount: 1))
      document.stateService.isOutputActive = true
      await #expect(throws: (any Error).self) {
        try await document.apply(snapshot: snapshot, previous: nil)
      }
      document.stateService.isOutputActive = false
    }

    @Test("Repeated hosting uses the same runtime controller")
    func stableRuntimeLifetime() async {
      let document = WorkspaceDocument()
      let representation = WorkspaceViewControllerRepresentation(document: document)
      let coordinator = representation.makeCoordinator()
      let first = coordinator.windowController
      let second = coordinator.windowController
      #expect(first === second)
      #expect(first.contentController === second.contentController)
      await coordinator.shutdown()
    }

    @Test("Document saves require an active editor and do not fall back to confirmed values")
    func disconnectedEditorCannotSave() async throws {
      let document = WorkspaceDocument()
      #expect(document.confirmedWorkspace == nil)
      await #expect(throws: (any Error).self) {
        try await document.snapshot(contentType: WorkspaceDocument.readableContentTypes[0])
      }
      let coordinator = WorkspaceViewControllerRepresentation(document: document).makeCoordinator()
      let state = coordinator.windowController.stateService
      state.workspaceDefinition.displayName = "Editing"
      #expect(document.confirmedWorkspace == nil)
      #expect(coordinator.snapshotForSaving().workspace.definition.displayName == "Editing")
      coordinator.disconnect()
      #expect(document.editingConnection == nil)
      await #expect(throws: (any Error).self) {
        try await document.snapshot(contentType: WorkspaceDocument.readableContentTypes[0])
      }
      await coordinator.shutdown()
    }

    @Test("Undo and Redo change only editing content; UI state is not undoable")
    func editingUndoRedo() async throws {
      let document = WorkspaceDocument()
      let coordinator = WorkspaceViewControllerRepresentation(document: document).makeCoordinator()
      let state = coordinator.windowController.stateService
      let undo = UndoManager()
      undo.groupsByEvent = false
      coordinator.setUndoManager(undo)
      state.inspectorSelector = .init(kind: .workspaceCanvas)
      state.visionResults[7] = "Runtime result"
      coordinator.recordEdits()
      #expect(!undo.canUndo)
      undo.beginUndoGrouping()
      state.workspaceDefinition.displayName = "Edited"
      coordinator.recordEdits()
      undo.endUndoGrouping()
      #expect(undo.canUndo)
      #expect(document.confirmedWorkspace == nil)
      undo.undo()
      #expect(state.workspaceDefinition.displayName == "Untitled")
      #expect(state.inspectorSelector == .init(kind: .workspaceCanvas))
      #expect(state.visionResults[7] == "Runtime result")
      #expect(undo.canRedo)
      undo.redo()
      #expect(state.workspaceDefinition.displayName == "Edited")
      #expect(document.confirmedWorkspace == nil)
      await coordinator.shutdown()
      #expect(!undo.canUndo)
    }

    @Test("Reading without an editor initializes later editing without registering Undo")
    func readBeforeEditorConnection() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let original = WorkspaceDocument()
      original.stateService.workspaceDefinition.displayName = "Loaded"
      try await saveWorkspaceDocument(original, to: root)
      let progress = ProgressManager(totalCount: 1)
      let read = try await WorkspaceDocument.Reader().read(
        from: root, progress: progress.subprogress(assigningCount: 1))
      let document = WorkspaceDocument()
      try await document.apply(snapshot: read, previous: nil)
      #expect(document.editingConnection == nil)
      #expect(document.confirmedWorkspace?.definition.displayName == "Loaded")
      let coordinator = WorkspaceViewControllerRepresentation(document: document).makeCoordinator()
      let undo = UndoManager()
      coordinator.setUndoManager(undo)
      coordinator.recordEdits()
      #expect(!undo.canUndo)
      #expect(coordinator.windowController.stateService.workspaceDefinition.displayName == "Loaded")
      #expect(coordinator.windowController.persistenceCoordinator.runtimeWorkspace == document.confirmedWorkspace)
      await coordinator.shutdown()
      await original.shutdown()
    }

    @Test("Dismantling releases the controller while the Document stays alive")
    func representationOwnsControllerLifetime() async {
      let document = WorkspaceDocument()
      var coordinator: WorkspaceViewControllerRepresentation.Coordinator? =
        WorkspaceViewControllerRepresentation(document: document).makeCoordinator()
      weak var owner = coordinator?.windowController
      if let coordinator {
        WorkspaceViewControllerRepresentation.dismantleNSViewController(
          coordinator.windowController.contentController, coordinator: coordinator)
        await coordinator.shutdown()
        await coordinator.shutdown()
      }
      coordinator = nil
      for _ in 0..<100 {
        if owner == nil { break }
        await Task.yield()
      }
      #expect(owner == nil)
      #expect(document.editingConnection == nil)
      #expect(document.confirmedWorkspace == nil)
    }
  }
}
