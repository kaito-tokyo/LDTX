// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreImage
import LDTXProgramRuntime
import LDTXProtos
import LDTXRichText
import LDTXVision
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletModel
@testable import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("Workspace DocumentGroup persistence", .serialized)
  @MainActor
  struct WorkspaceDocumentIntegrationTestSuite {
    @Test(
      "LUB-1071: Saving unchanged content recreates runtime variables; failed reads preserve them")
    func persistedAdoptionRecreatesVariables() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let document = WorkspaceDocument()
      let component = try document.controller.windowRuntime.addVFXSource(displayName: "Camera")
      let id = try document.controller.windowRuntime.addOcrVision(
        displayName: "OCR", videoComponentInternalID: component)
      document.stateService.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.visions[0].ocrVision.triggers = []
      }
      try await saveWorkspaceDocument(document, to: root)
      let saved = try WorkspaceBundleReaderV4(at: root).read()
      final class SavedContext: WorkspaceDocumentContext {
        let fileURL: URL?
        let runtimeWorkspace: WorkspaceV4Bundle?
        var lastContentModificationDate: Date?
        init(url: URL, workspace: WorkspaceV4Bundle) {
          fileURL = url
          runtimeWorkspace = workspace
          lastContentModificationDate = Date(timeIntervalSince1970: 1)
        }
      }
      let context = SavedContext(url: root, workspace: saved)
      let state = document.stateService
      let persistence = WorkspaceV4PersistenceCoordinator(
        workspaceSnapshot: { state.editingWorkspace },
        replaceWorkspace: { state.replaceEditingWorkspace($0, undoManager: nil) })
      try persistence.adoptRuntimeWorkspace(saved)
      let controller = WorkspaceAppletCoordinator(
        stateService: state, persistenceCoordinator: persistence,
        appletData: WorkspaceAppletData(), document: context)
      await controller.refreshPersistedWorkspace(at: root) { true }
      let runtime = controller.windowRuntime
      let key = LDTXVariableKey(visionID: id, item: .text)
      runtime.visionFeatureContext.reportVariables(id, [.text: "first"])
      await controller.refreshPersistedWorkspace(at: root) { true }
      #expect(try runtime.readVariable(key) == "first")
      context.lastContentModificationDate = Date(timeIntervalSince1970: 2)
      await controller.refreshPersistedWorkspace(at: root) { true }
      #expect(try runtime.readVariable(key) == "")
      runtime.visionFeatureContext.reportVariables(id, [.text: "second"])
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.visions[0].ocrVision.regionOfInterest.width.set(num: 1, den: 0)
      }
      await #expect(throws: (any Error).self) {
        try await saveWorkspaceDocument(document, to: root)
      }
      await controller.refreshPersistedWorkspace(at: root) { true }
      #expect(try runtime.readVariable(key) == "second")
      await controller.refreshPersistedWorkspace(at: root.appendingPathComponent("missing")) {
        true
      }
      #expect(try runtime.readVariable(key) == "second")
      await controller.shutdown()
      await document.shutdown()
    }

    @Test(
      "LUB-1071: Unchanged saves cancel pending manual classification without publishing stale state",
      arguments: ["success", "failure", "cancelled"], [false, true])
    func unchangedSaveCancelsManualClassification(outcome: String, publishNew: Bool) async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("Workspace.ldtxworkspace")
      let model = root.appendingPathComponent("Classifier.mlmodel")
      try Data([1]).write(to: model)
      let document = WorkspaceDocument()
      let editingState = document.stateService
      editingState.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents = [
          .with {
            $0.vfxSource = .with {
              $0.internalID = 7
              $0.displayName = "Camera"
              $0.deviceWidth = 1920
              $0.deviceHeight = 1080
            }
          }
        ]
      }
      editingState.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.visions = [
          .with {
            $0.ldtxSceneDetectorVision = .with {
              $0.internalID = 5
              $0.displayName = "Classifier"
              $0.videoComponentInternalID = 7
            }
          }
        ]
      }
      editingState.setVisionModelURL(model, for: 5, undoManager: nil)
      editingState.inspectorSelector = .init(kind: .ldtxSceneDetectorVision, internalID: 5)
      try await saveWorkspaceDocument(document, to: url)
      let saved = try WorkspaceBundleReaderV4(at: url).read()
      let state = WorkspaceDocument(
        definition: saved.definition, preferences: saved.preferences)
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.visionModels = saved.visionModels
      }
      state.inspectorSelector = .init(kind: .ldtxSceneDetectorVision, internalID: 5)
      final class SavedContext: WorkspaceDocumentContext {
        let fileURL: URL?
        init(url: URL) { fileURL = url }
      }
      let context = SavedContext(url: url)
      let persistence = WorkspaceV4PersistenceCoordinator(
        workspaceSnapshot: { state.editingWorkspace },
        replaceWorkspace: { state.replaceEditingWorkspace($0, undoManager: nil) })
      try persistence.adoptRuntimeWorkspace(saved)
      let runtime = WorkspaceWindowRuntime(
        persistence: persistence, captureSessionCoordinator: WorkspaceCaptureSessionCoordinator())
      let vision = saved.definition.visions[0].ldtxSceneDetectorVision
      let key = LDTXVariableKey(visionID: 5, item: .label)
      let oldContext = runtime.visionFeatureContext
      let dispatcher = ToolbarDispatcher()
      let started = AsyncStream<Void>.makeStream()
      var pending: CheckedContinuation<VisionClassificationResult, any Error>?
      dispatcher.classificationHandler = {
        try await runtime.classify(
          vision: vision,
          frameForSceneDetector: { WorkspaceVisionAnalysisFrame(image: CIImage()) },
          classifyResult: { _ in
            try await withCheckedThrowingContinuation {
              pending = $0
              started.continuation.yield(())
              started.continuation.finish()
            }
          })
      }
      let task = Task {
        await dispatcher.inferSelectedVision(
          stateService: state, document: context, runtimeWorkspace: { runtime.workspace })
      }
      var iterator = started.stream.makeAsyncIterator()
      _ = await iterator.next()
      defer { pending?.resume(throwing: CancellationError()) }
      #expect(state.isInferring)
      try await saveWorkspaceDocument(document, to: url)
      #expect(try WorkspaceBundleReaderV4(at: url).read() == saved)
      // Drive the same persisted-adoption boundary after the successful unchanged save.
      // Keep model preparation outside this deterministic manual-inference test.
      try persistence.adoptRuntimeWorkspace(try WorkspaceBundleReaderV4(at: url).read())
      #expect(!oldContext.isCurrent())
      #expect(try runtime.readVariable(key) == "")
      if publishNew {
        runtime.visionFeatureContext.reportResult(5, "New result")
        runtime.visionFeatureContext.reportVariables(5, [.label: "New label", .confidence: "0.9"])
        state.visionResults[5] = "New result"
        state.visionFailureMessages[5] = "New diagnostic"
      }
      let completion = try #require(pending)
      pending = nil
      switch outcome {
      case "failure": completion.resume(throwing: CocoaError(.fileReadUnknown))
      case "cancelled": completion.resume(throwing: CancellationError())
      default:
        completion.resume(returning: .init(candidates: [.init(label: "Stale", confidence: 0.8)]))
      }
      await task.value
      #expect(!state.isInferring)
      #expect(state.visionResults[5] == (publishNew ? "New result" : nil))
      #expect(state.visionFailureMessages[5] == (publishNew ? "New diagnostic" : nil))
      #expect(runtime.visionResults[5] == (publishNew ? "New result" : nil))
      #expect(runtime.visionFailureMessages[5] == nil)
      #expect(try runtime.readVariable(key) == (publishNew ? "New label" : ""))
      #expect(
        try runtime.readVariable(.init(visionID: 5, item: .confidence))
          == (publishNew ? "0.9" : "0"))
      await document.shutdown()
    }

    @Test(
      "LUB-1047: Persisted read failures are reported only for the current document URL",
      arguments: [false, true])
    func persistedReadFailureRequiresCurrentURL(isCurrent: Bool) async {
      let document = WorkspaceDocument()
      let coordinator = WorkspaceAppletCoordinator(document: document)
      let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      await coordinator.refreshPersistedWorkspace(at: missing) { isCurrent }
      #expect(document.operationErrors.count == (isCurrent ? 1 : 0))
      #expect(document.workspaceSnapshot == nil)
      #expect(document.recordingState == .idle)
      await coordinator.shutdown()
    }

    @Test("LUB-1047: Output requires canonical document content, runtime, and disk to agree")
    func outputValidatesCanonicalContentAndRejectsMismatches() async throws {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("ldtxworkspace")
      defer { try? FileManager.default.removeItem(at: url) }
      let document = WorkspaceDocument()
      try await saveWorkspaceDocument(document, to: url)
      final class SavedDocumentContext: WorkspaceDocumentContext {
        let fileURL: URL?
        let document: WorkspaceDocument
        var runtimeWorkspace: WorkspaceV4Bundle? { document.workspaceSnapshot }
        init(url: URL, document: WorkspaceDocument) {
          fileURL = url
          self.document = document
        }
      }
      let context = SavedDocumentContext(url: url, document: document)
      let state = document.stateService
      let persistence = WorkspaceV4PersistenceCoordinator(
        workspaceSnapshot: { state.editingWorkspace },
        replaceWorkspace: { state.replaceEditingWorkspace($0, undoManager: nil) }, url: url)
      try persistence.adoptRuntimeWorkspace(try WorkspaceBundleReaderV4(at: url).read())
      let controller = WorkspaceAppletCoordinator(
        stateService: state, persistenceCoordinator: persistence,
        appletData: WorkspaceAppletData(), document: context)
      defer { document.close() }
      try await controller.validateOutputWorkspace()
      let baseline = try WorkspaceBundleReaderV4(at: url).read()
      for field in [
        \WorkspaceV4Bundle.definitionExternalID, \WorkspaceV4Bundle.preferencesExternalID,
        \WorkspaceV4Bundle.outputSettingsExternalID,
      ] {
        var replacement = baseline
        replacement[keyPath: field] = WorkspaceBundleWriterV4.makeExternalID().uuidString
          .lowercased()
        try WorkspaceBundleWriterV4().write(replacement, to: url)
        await #expect(throws: (any Error).self) { try await controller.startOutput() }
        #expect(document.stateService.recordingState == .idle)
      }
      try WorkspaceBundleWriterV4().write(baseline, to: url)
      let newProgramID: Int64 = 123
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.programs.append(.with { $0.internalID = newProgramID })
      }
      _ = await (try controller.selectProgram(internalID: newProgramID)).value
      #expect(controller.appletData.state(for: url).selectedProgramInternalID == newProgramID)
      #expect(
        !controller.windowRuntime.definition.programs.contains { $0.internalID == newProgramID })
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.programs.removeAll { $0.internalID == newProgramID }
      }
      var staleRuntime = try WorkspaceBundleReaderV4(at: url).read()
      staleRuntime.definition.displayName = "Stale runtime"
      try persistence.adoptRuntimeWorkspace(staleRuntime)
      await #expect(throws: (any Error).self) { try await controller.startOutput() }
      try persistence.adoptRuntimeWorkspace(try WorkspaceBundleReaderV4(at: url).read())
      document.stateService.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.displayName = "Pending save"
      }
      let captured = try await document.snapshot(
        contentType: WorkspaceDocument.readableContentTypes[0])
      #expect(captured.definition.displayName == "Pending save")
      #expect(document.runtimeWorkspace == baseline)
      #expect(controller.windowRuntime.workspace == baseline)
      #expect(try WorkspaceBundleReaderV4(at: url).read() == baseline)
      // Capturing pending edits does not replace the last canonical read or start output.
      try await controller.validateOutputWorkspace()
      #expect(document.stateService.recordingState == .idle)
      // A mismatching canonical confirmation must still fail the output gate.
      document.confirmPersistedWorkspace(captured)
      await #expect(throws: (any Error).self) {
        try await controller.validateOutputWorkspace()
      }
      document.confirmPersistedWorkspace(baseline)
      try await saveWorkspaceDocument(document, to: url)
      try persistence.adoptRuntimeWorkspace(try WorkspaceBundleReaderV4(at: url).read())
      try await controller.validateOutputWorkspace()
      try FileManager.default.removeItem(at: url)
      await #expect(throws: (any Error).self) { try await controller.startOutput() }
      #expect(document.stateService.recordingState == .idle)
      await controller.shutdown()
      await document.shutdown()
    }

    @Test("LUB-1047: Reader applies content immediately and headless snapshots retain later edits")
    func headlessReadThenSave() async throws {
      let document = WorkspaceDocument()
      var read = document.stateService.editingWorkspace
      read.definition.displayName = "Read without UI"
      try await document.apply(snapshot: read, previous: nil)
      let first = try await document.snapshot(
        contentType: WorkspaceDocument.readableContentTypes[0])
      #expect(first == read)
      document.stateService.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.displayName = "Later edit"
      }
      let second = try await document.snapshot(
        contentType: WorkspaceDocument.readableContentTypes[0])
      #expect(second.definition.displayName == "Later edit")
      let coordinator = WorkspaceDocumentConnection(document: document)
      coordinator.synchronizeDocument()
      #expect(document.stateService.workspaceDefinition.displayName == "Later edit")
      await coordinator.shutdown()
    }
    @Test("LUB-1047: New Workspaces can be created and edited without saving")
    func unsavedCreationAndEditing() async throws {
      let first = WorkspaceDocument()
      let second = WorkspaceDocument()
      let firstID = try #require(first.stateService.externalID.flatMap(UUID.init(uuidString:)))
      let secondID = try #require(second.stateService.externalID.flatMap(UUID.init(uuidString:)))
      #expect(firstID != secondID)
      #expect(firstID.uuid.6 >> 4 == 7)
      let coordinator = WorkspaceDocumentConnection(document: first)
      let state = first.stateService
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.displayName = "Draft"
      }
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.programs = [
          .with {
            $0.internalID = 7
            $0.displayName = "Program"
          }
        ]
      }

      _ = await (try coordinator.runtimeCoordinator.selectProgram(internalID: 7)).value
      let localURL = try #require(state.localStateURL)
      #expect(
        coordinator.runtimeCoordinator.appletData.state(for: localURL)
          .selectedProgramInternalID == 7)
      #expect(first.fileURL == nil)
      #expect(first.workspaceSnapshot == nil)
      #expect(state.workspaceDefinition.programs.count == 1)
      #expect(state.externalID == firstID.uuidString.lowercased())
      #expect(!coordinator.runtimeCoordinator.persistenceCoordinator.hasPersistedWorkspace)
      await #expect(throws: (any Error).self) {
        try await coordinator.runtimeCoordinator.startOutput()
      }
      #expect(state.recordingState == .idle)
      #expect(state.workspaceDefinition.displayName == "Draft")
      await coordinator.shutdown()
    }

    @Test("LUB-1047: Saved documents round-trip all three Protobuf documents")
    func roundTrip() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("Workspace.ldtxworkspace")
      let document = WorkspaceDocument()
      document.stateService.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.displayName = "Main"
      }
      try await saveWorkspaceDocument(document, to: url)
      let reopened = try await loadWorkspaceDocument(at: url)
      #expect(reopened.workspace == document.workspace)
      #expect(reopened.fileURL == nil)
      #expect(reopened.testSavedURL == url)
      #expect(reopened.stateService.visionModels.isEmpty)
    }

    @Test("LUB-1047: Staged writes do not expose definitions before the formal save completes")
    func stagedWriteKeepsRuntimeDefinition() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("Formal.ldtxworkspace")
      let staged = root.appendingPathComponent("Staging.ldtxworkspace")
      let document = WorkspaceDocument()
      document.stateService.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.displayName = "Saved"
      }
      try await saveWorkspaceDocument(document, to: url)
      document.stateService.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.displayName = "Pending"
      }
      let snapshot = try await document.snapshot(
        contentType: WorkspaceDocument.readableContentTypes[0])
      #expect(document.workspace == snapshot)
      #expect(document.persistenceCoordinator.runtimeWorkspace.definition.displayName == "Saved")
      let progress = ProgressManager(totalCount: 1)
      try await WorkspaceDocument.Writer().write(
        snapshot: snapshot, to: staged, previous: nil,
        progress: progress.subprogress(assigningCount: 1))
      await document.refreshTestPersistedWorkspace()
      #expect(document.persistenceCoordinator.runtimeWorkspace.definition.displayName == "Saved")
      #expect(document.stateService.workspaceDefinition.displayName == "Pending")
      #expect(document.workspaceSnapshot?.definition.displayName == "Saved")
      #expect(try WorkspaceBundleReaderV4(at: url).read().definition.displayName == "Saved")
      try FileManager.default.removeItem(at: url)
      try FileManager.default.moveItem(at: staged, to: url)
      document.stateService.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.displayName = "Later"
      }
      await document.refreshTestPersistedWorkspace()
      #expect(document.persistenceCoordinator.runtimeWorkspace.definition.displayName == "Pending")
      #expect(document.stateService.workspaceDefinition.displayName == "Later")
    }

    @Test("LUB-1047: Write failure retains edits without publishing a captured snapshot")
    func writeFailureKeepsConfirmedContent() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      try Data([1]).write(to: root)
      let document = WorkspaceDocument()
      document.stateService.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.displayName = "Confirmed"
      }
      let snapshot = try await document.snapshot(
        contentType: WorkspaceDocument.readableContentTypes[0])
      document.stateService.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.displayName = "Later"
      }
      let progress = ProgressManager(totalCount: 1)
      await #expect(throws: (any Error).self) {
        try await WorkspaceDocument.Writer().write(
          snapshot: snapshot,
          to: root.appendingPathComponent("Impossible.ldtxworkspace"), previous: nil,
          progress: progress.subprogress(assigningCount: 1))
      }
      #expect(document.workspaceSnapshot == nil)
      #expect(document.stateService.workspaceDefinition.displayName == "Later")
      #expect(snapshot.definition.displayName == "Confirmed")
    }

    @Test("LUB-1047: Invalid data fails before creating a destination")
    func invalidDataDoesNotWrite() async throws {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "\(UUID()).ldtxworkspace")
      let document = WorkspaceDocument()
      document.stateService.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.programs = [.with { $0.internalID = 0 }]
      }
      do {
        try await saveWorkspaceDocument(document, to: url)
        Issue.record("Expected validation error")
      } catch { #expect(error is WorkspaceV4ValidationError) }
      #expect(!FileManager.default.fileExists(atPath: url.path))
      #expect(document.fileURL == nil)
    }

    @Test("LUB-1047: Preferences are visible to the runtime before saving")
    func livePreferences() async throws {
      let document = WorkspaceDocument()
      document.stateService.editWorkspace(undoManager: nil) { workspace in
        workspace.preferences.landscapeProgramPreferences[7] = .with {
          $0.audioMasterVolumeDecibels.set(num: -50, den: 10)
        }
      }
      #expect(
        document.persistenceCoordinator.runtimeWorkspace.preferences
          == document.stateService.workspacePreferences)
      #expect(
        document.persistenceCoordinator.runtimeWorkspace.definition
          != document.stateService.workspaceDefinition)
    }

    @Test("LUB-1047: Snapshots retain edits; invalid ROI fails on save without updating runtime")
    func invalidROIIsValidatedOnSave() async throws {
      let document = WorkspaceDocument()
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: url) }
      try await saveWorkspaceDocument(document, to: url)
      let persisted = document.persistenceCoordinator.runtimeWorkspace
      document.stateService.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents = [
          .with {
            $0.vfxSource = .with {
              $0.internalID = 7
              $0.displayName = "Camera"
              $0.deviceWidth = 1920
              $0.deviceHeight = 1080
            }
          }
        ]
      }
      document.stateService.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.visions = [
          .with {
            $0.ocrVision = .with {
              $0.internalID = 9
              $0.displayName = "OCR"
              $0.videoComponentInternalID = 7
            }
          }
        ]
      }
      document.stateService.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.visions[0].ocrVision.regionOfInterest.x
          .set(num: 2, den: 1)
      }
      let snapshot = try await document.snapshot(
        contentType: WorkspaceDocument.readableContentTypes[0])
      #expect(snapshot == document.stateService.editingWorkspace)
      #expect(document.workspace == snapshot)
      await #expect(throws: (any Error).self) { try await saveWorkspaceDocument(document, to: url) }
      #expect(document.persistenceCoordinator.runtimeWorkspace == persisted)
      #expect(
        document.stateService.workspaceDefinition.visions[0].ocrVision.regionOfInterest.x.num == 2)
    }

    @Test("LUB-1047: A reload explicitly overwrites the editing documents")
    func reloadOverwritesEditingState() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("Workspace.ldtxworkspace")
      let document = WorkspaceDocument()
      try await saveWorkspaceDocument(document, to: url)
      let progress = ProgressManager(totalCount: 1)
      let previous = try await WorkspaceDocument.Reader().read(
        from: url, progress: progress.subprogress(assigningCount: 1))
      var external = previous
      external.definition.displayName = "External"
      try WorkspaceBundleWriterV4().write(external, to: url)
      let readProgress = ProgressManager(totalCount: 1)
      let incoming = try await WorkspaceDocument.Reader().read(
        from: url, progress: readProgress.subprogress(assigningCount: 1))
      document.stateService.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.displayName = "Local"
      }
      try await document.apply(snapshot: incoming, previous: previous)
      document.testCoordinator.synchronizeDocument()
      await document.refreshTestPersistedWorkspace()
      #expect(document.stateService.workspaceDefinition.displayName == "External")
      #expect(document.persistenceCoordinator.runtimeWorkspace.definition.displayName == "External")
    }

    @Test("LUB-1047: Applying a content snapshot does not give a standalone document a URL")
    func applyingSnapshotDoesNotRestoreSourceURL() async throws {
      let document = WorkspaceDocument()
      let source = WorkspaceV4Bundle(definition: .init(), preferences: .init())
      try await document.apply(snapshot: source, previous: nil)
      #expect(document.workspaceSnapshot == source)
      #expect(document.fileURL == nil)
    }

    @Test("LUB-1047: Reader apply is immediate and URL synchronization preserves subsequent edits")
    func explicitSynchronizationModes() async throws {
      let document = WorkspaceDocument()
      let coordinator = document.testCoordinator
      let state = document.stateService
      var incoming = state.editingWorkspace
      incoming.definition.displayName = "Read from disk"
      incoming.visionModels = [
        11: URL(fileURLWithPath: "/Saved/11/Model.mlmodel"),
        13: URL(fileURLWithPath: "/Saved/13/Other.mlpackage"),
      ]
      try await document.apply(snapshot: incoming, previous: nil)
      #expect(state.editingWorkspace == incoming)
      #expect(document.workspaceSnapshot == incoming)
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.displayName = "Local edits"
      }
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.preferences.audioChannelGainsDecibels[7] = .with {
          $0.set(num: -20, den: 10)
        }
      }
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.outputSettings.recordingEnabled = true
      }
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definitionExternalID = "Local definition envelope"
      }
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.preferencesExternalID = "Local preferences envelope"
      }
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.outputSettingsExternalID = "Local output envelope"
      }
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.visionModels = [
          11: URL(fileURLWithPath: "/External/Model.mlmodel"),
          15: URL(fileURLWithPath: "/External/Pending.mlpackage"),
        ]
      }
      state.inspectorSelector = .init(kind: .workspaceCanvas)
      let local = state.editingWorkspace
      for (id, url) in incoming.visionModels where state.visionModels[id] != nil {
        state.editWorkspace(undoManager: nil) { workspace in
          workspace.visionModels[id] = url
        }
      }
      var expected = local
      expected.visionModels[11] = incoming.visionModels[11]
      #expect(state.editingWorkspace == expected)
      #expect(state.visionModels[13] == nil)
      #expect(state.visionModels[15] == local.visionModels[15])

      // Reader applied synchronously. Later edits and explicit URL replacements
      // belong to the current editable value; URL routing must not replay the read.
      coordinator.synchronizeDocument()
      #expect(state.editingWorkspace == expected)
      #expect(document.workspaceSnapshot == incoming)
      #expect(state.visionModels[13] == nil)
      #expect(state.visionModels[15] == local.visionModels[15])
      #expect(state.inspectorSelector == .init(kind: .workspaceCanvas))
      await coordinator.shutdown()
    }

    @Test("LUB-1047: UI observes document changes and the host supplies the runtime's saved URL")
    func consumersObserveDocumentChanges() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let document = WorkspaceDocument()
      try await saveWorkspaceDocument(document, to: root)
      let previous = try #require(document.workspaceSnapshot)
      var incoming = previous
      incoming.definition.displayName = "Observed"
      try WorkspaceBundleWriterV4().write(incoming, to: root)
      try await document.apply(snapshot: incoming, previous: previous)
      await document.refreshTestPersistedWorkspace()
      for _ in 0..<200 {
        if document.stateService.workspaceDefinition.displayName == "Observed",
          document.persistenceCoordinator.runtimeWorkspace.definition.displayName == "Observed"
        {
          break
        }
        try await Task.sleep(for: .milliseconds(5))
      }
      #expect(document.stateService.workspaceDefinition.displayName == "Observed")
      #expect(document.persistenceCoordinator.runtimeWorkspace.definition.displayName == "Observed")
      await document.shutdown()
    }

    @Test("LUB-1047: Missing or malformed packages are rejected")
    func corruptRead() async throws {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let progress = ProgressManager(totalCount: 1)
      await #expect(throws: (any Error).self) {
        try await WorkspaceDocument.Reader().read(
          from: url, progress: progress.subprogress(assigningCount: 1))
      }
    }

    @Test(
      "LUB-1047: Model IDs are assigned on selection and saving preserves newer choices and history"
    )
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
      document.stateService.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents = [
          .with {
            $0.vfxSource = .with {
              $0.internalID = 7
              $0.displayName = "Camera"
              $0.deviceWidth = 1920
              $0.deviceHeight = 1080
            }
          }
        ]
      }
      document.stateService.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.visions = [
          .with {
            $0.ldtxSceneDetectorVision = .with {
              $0.internalID = 5
              $0.displayName = "Classifier"
              $0.videoComponentInternalID = 7
            }
          }
        ]
      }
      let state = document.stateService
      state.setVisionModelURL(first, for: 5, undoManager: nil)
      let firstID = state.workspaceDefinition.visions[0].ldtxSceneDetectorVision.modelInternalID
      #expect(firstID > 0)
      state.setVisionModelURL(first, for: 5, undoManager: nil)
      #expect(
        state.workspaceDefinition.visions[0].ldtxSceneDetectorVision.modelInternalID == firstID)
      let snapshot = try await document.snapshot(
        contentType: WorkspaceDocument.readableContentTypes[0])
      #expect(snapshot.definition.visions[0].ldtxSceneDetectorVision.modelInternalID == firstID)
      state.setVisionModelURL(second, for: 5, undoManager: nil)
      let secondID = state.workspaceDefinition.visions[0].ldtxSceneDetectorVision.modelInternalID
      #expect(secondID != firstID)
      let progress = ProgressManager(totalCount: 1)
      try await WorkspaceDocument.Writer().write(
        snapshot: snapshot, to: url, previous: nil,
        progress: progress.subprogress(assigningCount: 1))
      document.testSavedURL = url
      document.controller.adoptDocumentURL(url)
      await document.refreshTestPersistedWorkspace()
      #expect(
        state.workspaceDefinition.visions[0].ldtxSceneDetectorVision.modelInternalID == secondID)
      #expect(state.visionModels[secondID] == second)
      let firstURL = url.appendingPathComponent("VisionModels/\(firstID)/First.mlmodel")
      #expect(try Data(contentsOf: firstURL) == Data([1]))
      try await saveWorkspaceDocument(document, to: url)
      let secondURL = url.appendingPathComponent("VisionModels/\(secondID)/Second.mlmodel")
      #expect(state.visionModels[firstID] == first)
      #expect(state.visionModels[secondID] == second)
      #expect(
        document.workspaceSnapshot?.visionModels[firstID]?.resolvingSymlinksInPath()
          == firstURL.resolvingSymlinksInPath())
      #expect(
        document.workspaceSnapshot?.visionModels[secondID]?.resolvingSymlinksInPath()
          == secondURL.resolvingSymlinksInPath())
      let reloaded = try WorkspaceBundleReaderV4(at: url).read()
      #expect(
        reloaded.visionModels[firstID]?.resolvingSymlinksInPath()
          == firstURL.resolvingSymlinksInPath())
      #expect(
        reloaded.visionModels[secondID]?.resolvingSymlinksInPath()
          == secondURL.resolvingSymlinksInPath())
      #expect(try Data(contentsOf: firstURL) == Data([1]))
      #expect(try Data(contentsOf: secondURL) == Data([2]))
      state.setVisionModelURL(nil, for: 5, undoManager: nil)
      #expect(state.workspaceDefinition.visions[0].ldtxSceneDetectorVision.modelInternalID == 0)
      try await saveWorkspaceDocument(document, to: url)
      #expect(try Data(contentsOf: firstURL) == Data([1]))
      #expect(try Data(contentsOf: secondURL) == Data([2]))
      let missing = root.appendingPathComponent("Missing.mlmodel")
      state.setVisionModelURL(missing, for: 5, undoManager: nil)
      let missingID = state.workspaceDefinition.visions[0].ldtxSceneDetectorVision.modelInternalID
      let saved = document.persistenceCoordinator.runtimeWorkspace
      do {
        try await saveWorkspaceDocument(document, to: url)
        Issue.record("Expected read failure")
      } catch {}
      #expect(document.persistenceCoordinator.runtimeWorkspace == saved)
      #expect(state.visionModels[missingID] == missing)
    }

    @Test("LUB-1047: Document accepts reloads during output while the runtime retains its copy")
    func outputDefersRuntimeReload() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let document = WorkspaceDocument()
      document.stateService.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.displayName = "Original"
      }
      try await saveWorkspaceDocument(document, to: root)
      let previous = try #require(document.workspaceSnapshot)
      var incoming = previous
      incoming.definition.displayName = "External"
      try WorkspaceBundleWriterV4().write(incoming, to: root)
      document.stateService.isOutputActive = true
      try await document.apply(snapshot: incoming, previous: previous)
      #expect(document.workspaceSnapshot == incoming)
      document.testCoordinator.synchronizeDocument()
      #expect(document.stateService.workspaceDefinition.displayName == "External")
      await document.refreshTestPersistedWorkspace()
      #expect(document.persistenceCoordinator.runtimeWorkspace.definition.displayName == "Original")
      document.stateService.isOutputActive = false
      await document.refreshTestPersistedWorkspace()
      #expect(document.persistenceCoordinator.runtimeWorkspace.definition.displayName == "External")
    }

    @Test("LUB-1030: SwiftUI reconstruction preserves runtime lifetime and close releases it once")
    func stableRuntimeLifetime() async throws {
      let resources = WorkspaceRuntimeFixture()
      var released: [UUID] = []
      let document = WorkspaceDocument()
      let coordinator = WorkspaceAppletCoordinator(
        document: document, landscapeRuntime: resources.landscape,
        portraitRuntime: resources.portrait, metalView: resources.metalView,
        captureSessionCoordinator: resources.capture,
        onShutdown: { released.append(document.runtimeID) })
      let delegate = WorkspaceAppletDelegateFixture(coordinator: coordinator)
      func scene() -> some View {
        WorkspaceDocumentContent(document: document)
          .environment(\.workspaceAppletDelegate, delegate)
      }
      let host = NSHostingController(rootView: scene())
      let window = NSWindow(contentViewController: host)
      window.isReleasedWhenClosed = false
      window.setContentSize(.init(width: 1062, height: 700))
      window.makeKeyAndOrderFront(nil)
      defer { window.close() }
      await settleWorkspaceToolbar(window)
      let renderer = try #require(resources.metalView.delegate)
      #expect(resources.metalView.superview != nil)
      var responder: NSResponder? = window.contentView
      var seen: Set<ObjectIdentifier> = []
      var documentActions: WorkspaceDocumentActions?
      while let current = responder, seen.insert(ObjectIdentifier(current)).inserted {
        if let actions = current as? WorkspaceDocumentActions {
          documentActions = actions
          break
        }
        responder = current.nextResponder
      }
      #expect(documentActions != nil)
      #expect(window.toolbar != nil)
      host.rootView = scene()
      document.stateService.isSidebarVisible = false
      await settleWorkspaceToolbar(window)
      #expect(resources.metalView.delegate === renderer)
      #expect(released.isEmpty)
      window.miniaturize(nil)
      await settleWorkspaceToolbar(window)
      #expect(released.isEmpty)
      #expect(resources.metalView.delegate === renderer)
      window.deminiaturize(nil)
      window.close()
      for _ in 0..<100 {
        if !released.isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(released == [document.runtimeID])
      #expect(resources.metalView.delegate == nil)
      #expect(resources.metalView.isPaused)
    }

    @Test("LUB-1047: Document owns editing state and can save without a represented UI")
    func documentOwnsEditingState() async throws {
      let document = WorkspaceDocument()
      let state = document.stateService
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.displayName = "Editing"
      }
      let snapshot = try await document.snapshot(
        contentType: WorkspaceDocument.readableContentTypes[0])
      #expect(snapshot.definition.displayName == "Editing")
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: url) }
      let progress = ProgressManager(totalCount: 1)
      try await WorkspaceDocument.Writer().write(
        snapshot: snapshot, to: url, previous: nil,
        progress: progress.subprogress(assigningCount: 1))
      #expect(try WorkspaceBundleReaderV4(at: url).read() == snapshot)
      let coordinator = WorkspaceDocumentConnection(document: document)
      #expect(coordinator.runtimeCoordinator.stateService === state)
      coordinator.disconnect()
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.displayName = "Disconnected"
      }
      let disconnected = try await document.snapshot(
        contentType: WorkspaceDocument.readableContentTypes[0])
      #expect(disconnected.definition.displayName == "Disconnected")
      await coordinator.shutdown()
      #expect(document.stateService === state)
    }

    @Test("LUB-1047: Reading without an editor initializes later editing without registering Undo")
    func readBeforeUIRepresentation() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let original = WorkspaceDocument()
      original.stateService.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.displayName = "Loaded"
      }
      try await saveWorkspaceDocument(original, to: root)
      let progress = ProgressManager(totalCount: 1)
      let read = try await WorkspaceDocument.Reader().read(
        from: root, progress: progress.subprogress(assigningCount: 1))
      let document = WorkspaceDocument()
      try await document.apply(snapshot: read, previous: nil)
      #expect(document.workspaceSnapshot?.definition.displayName == "Loaded")
      let coordinator = WorkspaceDocumentConnection(document: document)
      await coordinator.runtimeCoordinator.refreshPersistedWorkspace(at: root) { true }
      let undo = UndoManager()

      #expect(!undo.canUndo)
      #expect(
        coordinator.runtimeCoordinator.stateService.workspaceDefinition.displayName == "Loaded")
      #expect(
        coordinator.runtimeCoordinator.persistenceCoordinator.runtimeWorkspace
          == document.workspaceSnapshot)
      await coordinator.shutdown()
      await original.shutdown()
    }

    @Test("LUB-1030: Dismantling releases the controller while the Document stays alive")
    func representationOwnsControllerLifetime() async {
      let document = WorkspaceDocument()
      var coordinator: WorkspaceDocumentConnection? =
        WorkspaceDocumentConnection(document: document)
      weak var owner = coordinator?.runtimeCoordinator
      if let coordinator {
        coordinator.disconnect()
        await coordinator.shutdown()
        await coordinator.shutdown()
      }
      coordinator = nil
      for _ in 0..<100 {
        if owner == nil { break }
        await Task.yield()
      }
      #expect(owner == nil)
      document.stateService.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.displayName = "Still editable"
      }
      #expect(document.stateService.workspaceDefinition.displayName == "Still editable")
      #expect(document.workspaceSnapshot == nil)
    }
  }
}
