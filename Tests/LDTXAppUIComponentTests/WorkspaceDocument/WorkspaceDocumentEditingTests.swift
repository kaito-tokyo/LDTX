// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXCorelibs
@testable import LDTXWorkspaceAppletService
@testable import LDTXWorkspaceAppletUI
import Observation
import SwiftUI
import Synchronization
import Testing

extension AppUIComponentTestSuite {
  @Suite("Workspace synchronous document editing", .serialized)
  @MainActor
  struct WorkspaceDocumentEditingUnitTestSuite {
    @Test("LUB-1047: Apply is immediate and snapshot preserves later edits")
    func applyIsImmediateAndSnapshotPreservesLaterEdits() async throws {
      let document = WorkspaceDocument()
      let undo = UndoManager()
      undo.groupsByEvent = false
      document.isSidebarVisible = false
      document.visionResults[7] = "Live result"
      var incoming = document.workspace
      incoming.definition.displayName = "Canonical read"
      incoming.visionModels[11] = URL(fileURLWithPath: "/Saved/11/Model.mlmodel")
      try await document.apply(snapshot: incoming, previous: nil)
      #expect(document.workspace == incoming)
      #expect(document.workspaceSnapshot == incoming)
      #expect(!undo.canUndo)
      #expect(!document.isSidebarVisible)
      #expect(document.visionResults[7] == "Live result")
      undo.beginUndoGrouping()
      document.editWorkspace(undoManager: undo) {
        $0.definition.displayName = "Local edit after reading"
        $0.outputSettings.recordingEnabled = true
        $0.visionModels[15] = URL(fileURLWithPath: "/Pending/15/Model.mlpackage")
      }
      undo.endUndoGrouping()
      let pending = document.workspace
      let captured = try await document.snapshot(
        contentType: WorkspaceDocument.readableContentTypes[0])
      #expect(captured == pending)
      #expect(document.workspace == pending)
      #expect(document.workspaceSnapshot == incoming)
      undo.undo()
      #expect(document.workspace == incoming)
      #expect(document.workspaceSnapshot == incoming)
      undo.redo()
      #expect(document.workspace == pending)
      #expect(document.workspaceSnapshot == incoming)
    }

    @Test("LUB-1047: Unchanged persisted confirmation does not notify or replace pending edits")
    func unchangedPersistedConfirmationDoesNotNotifyOrReplacePendingEdits() {
      let document = WorkspaceDocument()
      let saved = document.workspace
      document.confirmPersistedWorkspace(saved)
      document.editWorkspace(undoManager: nil) { $0.outputSettings.recordingEnabled = true }
      let pending = document.workspace
      let changed = Mutex(false)
      withObservationTracking {
        _ = document.workspaceSnapshot
      } onChange: {
        changed.withLock { $0 = true }
      }
      document.confirmPersistedWorkspace(saved)
      #expect(!changed.withLock { $0 })
      #expect(document.workspace == pending)
      var nextSave = saved
      nextSave.definition.displayName = "New canonical content"
      document.confirmPersistedWorkspace(nextSave)
      #expect(changed.withLock { $0 })
      #expect(document.workspaceSnapshot == nextSave)
      #expect(document.workspace == pending)
    }

    @Test("LUB-1031: Reverse registration uses the manager executing undo")
    func reverseRegistrationUsesTheManagerExecutingUndo() {
      let document = WorkspaceDocument()
      let originalManager = UndoManager()
      originalManager.groupsByEvent = false
      let otherManager = UndoManager()
      otherManager.groupsByEvent = false
      let original = document.workspace
      originalManager.beginUndoGrouping()
      document.editWorkspace(undoManager: originalManager) { $0.definition.displayName = "Edited" }
      originalManager.endUndoGrouping()
      let edited = document.workspace
      // There is no stored connection to redirect the inverse operation.
      originalManager.undo()
      #expect(document.workspace == original)
      #expect(originalManager.canRedo)
      #expect(!otherManager.canUndo)
      originalManager.redo()
      #expect(document.workspace == edited)
      #expect(originalManager.canUndo)
      originalManager.undo()
      #expect(document.workspace == original)
    }

    @Test("LUB-1031: First edit undo, redo, no op, and new edit history")
    func noOpPreservesRedoAndNewEditInvalidatesIt() {
      let document = WorkspaceDocument()
      let undo = UndoManager()
      undo.groupsByEvent = false
      let original = document.workspace

      undo.beginUndoGrouping()
      document.editWorkspace(undoManager: undo) { $0.definition.displayName = "First" }
      undo.endUndoGrouping()
      undo.undo()
      #expect(document.workspace == original)
      #expect(undo.canRedo)
      undo.redo()
      #expect(document.workspace.definition.displayName == "First")
      undo.undo()
      #expect(undo.canRedo)
      document.editWorkspace(undoManager: undo) {
        $0.definition.displayName = document.workspace.definition.displayName
      }
      #expect(!undo.canUndo)
      #expect(undo.canRedo)
      undo.beginUndoGrouping()
      document.editWorkspace(undoManager: undo) { $0.definition.displayName = "Second" }
      undo.endUndoGrouping()
      #expect(undo.canUndo)
      #expect(!undo.canRedo)
    }

    @Test("LUB-1031: Throwing edit does not change content or history")
    func throwingEditDoesNotChangeContentOrHistory() {
      enum Failure: Error { case invalid }
      let document = WorkspaceDocument()
      let undo = UndoManager()
      undo.groupsByEvent = false

      let original = document.workspace
      do {
        try document.editWorkspace(undoManager: undo) {
          $0.definition.displayName = "Incomplete"
          throw Failure.invalid
        }
        Issue.record("The mutation must throw")
      } catch {}
      #expect(document.workspace == original)
      #expect(!undo.canUndo)
    }

    @Test("LUB-1031: Document does not open or close undo groups")
    func documentDoesNotOpenOrCloseUndoGroups() {
      let document = WorkspaceDocument()
      let undo = UndoManager()
      undo.groupsByEvent = false

      let original = document.workspace
      undo.beginUndoGrouping()
      let level = undo.groupingLevel
      document.editWorkspace(undoManager: undo) { $0.definition.displayName = "One" }
      document.editWorkspace(undoManager: undo) { $0.outputSettings.recordingEnabled = true }
      #expect(undo.groupingLevel == level)
      undo.endUndoGrouping()
      let edited = document.workspace
      undo.undo()
      #expect(document.workspace == original)
      #expect(!undo.canUndo)
      undo.redo()
      #expect(document.workspace == edited)
    }

    @Test("LUB-1031: Manager is not retained by the document or its undo handler")
    func managerIsNotRetainedByTheDocumentOrItsUndoHandler() {
      let document = WorkspaceDocument()
      weak var releasedManager: UndoManager?
      do {
        let undo = UndoManager()
        releasedManager = undo
        undo.groupsByEvent = false

        undo.beginUndoGrouping()
        document.editWorkspace(undoManager: undo) { $0.definition.displayName = "Edited" }
        undo.endUndoGrouping()
      }
      #expect(releasedManager == nil)
    }

    @Test("LUB-1031: Deletion is one undo for definition and both canvas preferences")
    func deletionIsOneUndoForDefinitionAndBothCanvasPreferences() {
      let document = WorkspaceDocument(
        definition: .with {
          $0.videoComponents = [
            .with { $0.videoComponent = .vfxSource(.with { $0.internalID = 7 }) }
          ]
          $0.canvasConfiguration = .with {
            $0.ptsMasterVfxSourceInternalID = 7
          }
        },
        preferences: .with {
          $0.landscapeProgramPreferences[1] = .with { $0.videoLayerInternalIds = [7] }
          $0.portraitProgramPreferences[2] = .with { $0.videoLayerInternalIds = [7] }
        })
      let undo = UndoManager()
      undo.groupsByEvent = false

      let original = document.workspace
      undo.beginUndoGrouping()
      VideoComponentDeletion.delete(7, from: document, undoManager: undo)
      undo.endUndoGrouping()
      let deleted = document.workspace
      #expect(deleted.definition.videoComponents.isEmpty)
      #expect(deleted.definition.canvasConfiguration?.ptsMasterVfxSourceInternalID == nil)
      #expect(deleted.preferences.landscapeProgramPreferences[1]?.videoLayerInternalIds == [])
      #expect(deleted.preferences.portraitProgramPreferences[2]?.videoLayerInternalIds == [])
      undo.undo()
      #expect(document.workspace == original)
      #expect(!undo.canUndo)
      undo.redo()
      #expect(document.workspace == deleted)
    }

    @Test("LUB-1031: One edit restores all content without restoring UI state")
    func oneEditRestoresAllContentWithoutRestoringUIState() {
      let document = WorkspaceDocument()
      let undo = UndoManager()
      undo.groupsByEvent = false

      let original = document.workspace
      undo.beginUndoGrouping()
      document.editWorkspace(undoManager: undo) {
        $0.definition.displayName = "Edited"
        $0.preferences.audioChannelGainsDecibels[7] = .with { $0.set(num: -12, den: 1) }
        $0.outputSettings.recordingEnabled = true
        $0.visionModels[7] = URL(fileURLWithPath: "/tmp/one-edit.mlpackage")
      }
      undo.endUndoGrouping()
      let edited = document.workspace
      document.isSidebarVisible = false
      document.visionResults[7] = "Live result"
      #expect(undo.canUndo)
      undo.undo()
      #expect(document.workspace == original)
      #expect(!undo.canUndo)
      #expect(!document.isSidebarVisible)
      #expect(document.visionResults[7] == "Live result")
      #expect(undo.canRedo)
      undo.redo()
      #expect(document.workspace == edited)
    }

    @Test("LUB-1047: Reading does not create undo and snapshot does not publish content")
    func readingDoesNotCreateUndoAndSnapshotDoesNotPublishContent() async throws {
      let document = WorkspaceDocument()
      let undo = UndoManager()
      undo.groupsByEvent = false

      var loaded = document.workspace
      loaded.definition.displayName = "Loaded"
      try await document.apply(snapshot: loaded, previous: nil)
      #expect(document.workspace == loaded)
      #expect(!undo.canUndo)
      undo.beginUndoGrouping()
      document.editingBinding(\.definition, undoManager: undo).wrappedValue.displayName =
        "Edited after read"
      undo.endUndoGrouping()
      #expect(undo.canUndo)
      let captured = try await document.snapshot(
        contentType: WorkspaceDocument.readableContentTypes[0])
      #expect(captured == document.workspace)
      #expect(document.workspaceSnapshot == loaded)
      #expect(document.workspaceSnapshot != captured)
      undo.undo()
      #expect(document.workspace == loaded)
    }

    @Test("LUB-1031: Model choice registers one undo for identifier and asset")
    func modelChoiceRegistersOneUndoForIdentifierAndAsset() throws {
      let definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4.with {
        $0.visions = [.with { $0.vision = .ldtxSceneDetectorVision(.with { $0.internalID = 1 }) }]
      }
      let document = WorkspaceDocument(definition: definition)
      let undo = UndoManager()
      undo.groupsByEvent = false

      let original = document.workspace
      let model = URL(fileURLWithPath: "/tmp/model-choice.mlpackage")
      undo.beginUndoGrouping()
      document.setVisionModelURL(model, for: 1, undoManager: undo)
      undo.endUndoGrouping()
      let selected = document.workspace
      guard case .ldtxSceneDetectorVision(let vision) = selected.definition.visions[0].vision else {
        Issue.record("Missing classifier")
        return
      }
      let id = try #require(vision.modelInternalID)
      #expect(id > 0)
      #expect(selected.visionModels[id] == model)
      undo.undo()
      #expect(document.workspace == original)
      #expect(!undo.canUndo)
      undo.redo()
      #expect(document.workspace == selected)
    }
  }
}

extension AppUIComponentTestSuite {
  @Suite("Workspace snapshot writing without a represented editor", .serialized)
  @MainActor
  struct WorkspaceDocumentWritingIntegrationTestSuite {
    @Test("LUB-1047: Staging write preserves canonical output inputs")
    func stagingWritePreservesCanonicalOutputInputs() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let canonicalURL = root.appendingPathComponent("Canonical.ldtxworkspace")
      let stagedURL = root.appendingPathComponent("Staged.ldtxworkspace")
      let document = WorkspaceDocument()
      try WorkspaceBundleWriterV4().write(document.workspace, to: canonicalURL)
      let canonical = try WorkspaceBundleReaderV4(at: canonicalURL).read()
      try await document.apply(snapshot: canonical, previous: nil)
      let persistence = WorkspaceV4PersistenceCoordinator(
        workspaceSnapshot: { document.workspace },
        replaceWorkspace: { document.replaceEditingWorkspace($0, undoManager: nil) },
        url: canonicalURL)
      try persistence.adoptRuntimeWorkspace(canonical)
      document.editWorkspace(undoManager: nil) { $0.definition.displayName = "Unwritten edit" }
      let captured = try await document.snapshot(
        contentType: WorkspaceDocument.readableContentTypes[0])
      let progress = ProgressManager(totalCount: 1)
      try await WorkspaceDocument.Writer().write(
        snapshot: captured, to: stagedURL, previous: nil,
        progress: progress.subprogress(assigningCount: 1))
      #expect(captured.definition.displayName == "Unwritten edit")
      #expect(try WorkspaceBundleReaderV4(at: stagedURL).read() == captured)
      #expect(document.workspace == captured)
      #expect(document.runtimeWorkspace == canonical)
      #expect(persistence.persistedWorkspace == canonical)
      #expect(persistence.runtimeWorkspace == canonical)
      #expect(try WorkspaceBundleReaderV4(at: canonicalURL).read() == canonical)
      #expect(document.recordingState == .idle)
      #expect(!document.isOutputActive)
    }

    @Test(
      "LUB-1047: Writer retains later edits and does not publish persistence",
      arguments: [false, true], [false, true])
    func writerRetainsLaterEditsAndDoesNotPublishPersistence(
      fail: Bool, hasCanonicalRead: Bool
    ) async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let document = WorkspaceDocument()
      let loaded = document.workspace
      #expect(document.workspaceSnapshot == nil)
      if hasCanonicalRead { try await document.apply(snapshot: loaded, previous: nil) }
      let canonicalBeforeWriting = document.workspaceSnapshot
      #expect(canonicalBeforeWriting == (hasCanonicalRead ? loaded : nil))
      document.editWorkspace(undoManager: nil) { $0.definition.displayName = "Captured" }
      let snapshot = try await document.snapshot(
        contentType: WorkspaceDocument.readableContentTypes[0])
      #expect(document.workspaceSnapshot == canonicalBeforeWriting)
      document.editWorkspace(undoManager: nil) { $0.definition.displayName = "Later edit" }
      let destination: URL
      if fail {
        let blocker = root.appendingPathComponent("File")
        try Data([1]).write(to: blocker)
        destination = blocker.appendingPathComponent("Impossible.ldtxworkspace")
      } else {
        destination = root.appendingPathComponent("Saved.ldtxworkspace")
      }
      let progress = ProgressManager(totalCount: 1)
      do {
        try await WorkspaceDocument.Writer().write(
          snapshot: snapshot, to: destination, previous: nil,
          progress: progress.subprogress(assigningCount: 1))
        #expect(!fail)
        #expect(
          try WorkspaceBundleReaderV4(at: destination).read().definition.displayName == "Captured")
      } catch {
        #expect(fail)
      }
      #expect(document.workspace.definition.displayName == "Later edit")
      #expect(document.workspaceSnapshot == canonicalBeforeWriting)
      #expect(snapshot.definition.displayName == "Captured")
    }
  }
}
