// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import Testing

extension AppUIComponentTestSuite {
  @Suite("Workspace Document model selection", .serialized)
  @MainActor
  struct WorkspaceDocumentModelSelectionIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    @Test("Selected URLs become saved basenames only after successful saving")
    func savesSelectedModelURL() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let source = root.appendingPathComponent("Original.mlmodel")
      let bytes = Data([1, 2, 3])
      try bytes.write(to: source)
      let document = WorkspaceDocument()
      defer { document.close() }
      document.storeService.workspaceDefinition.videoComponents = [
        .with {
          $0.vfxSource = .with {
            $0.internalID = 7
            $0.displayName = "Camera"
            $0.deviceWidth = 1920
            $0.deviceHeight = 1080
          }
        }
      ]
      document.storeService.workspaceDefinition.visions = [
        .with {
          $0.ldtxSceneDetectorVision = .with {
            $0.internalID = 5
            $0.displayName = "Classifier"
            $0.videoComponentInternalID = 7
          }
        }
      ]
      document.storeService.modelURLs[5] = source
      #expect(document.isDocumentEdited)
      #expect(
        document.storeService.workspaceDefinition.visions[0].ldtxSceneDetectorVision
          .modelFileName == "")
      let url = root.appendingPathComponent("Workspace.ldtxworkspace")
      try await saveWorkspaceDocument(document, to: url)
      let savedURL = url.appendingPathComponent("VisionModels/5/Original.mlmodel")
      #expect(try Data(contentsOf: savedURL) == bytes)
      #expect(
        document.storeService.workspaceDefinition.visions[0].ldtxSceneDetectorVision
          .modelFileName == "Original.mlmodel")
      #expect(!document.storeService.modelURLs.keys.contains(5))
      #expect(!document.isDocumentEdited)
      let missing = root.appendingPathComponent("Missing.mlmodel")
      document.storeService.modelURLs[5] = missing
      do {
        try await saveWorkspaceDocument(document, to: url, operation: .saveOperation)
        Issue.record("Expected model read failure")
      } catch {}
      #expect(document.storeService.modelURLs[5] == .some(missing))
      #expect(
        document.storeService.workspaceDefinition.visions[0].ldtxSceneDetectorVision
          .modelFileName == "Original.mlmodel")
      #expect(try Data(contentsOf: savedURL) == bytes)
      #expect(document.isDocumentEdited)
      let reloaded = WorkspaceDocument()
      defer { reloaded.close() }
      try reloaded.read(from: url, ofType: "tokyo.kaito.ldtx.workspace")
      #expect(reloaded.storeService.modelURLs.isEmpty)
      #expect(
        reloaded.storeService.workspaceDefinition.visions[0].ldtxSceneDetectorVision
          .modelFileName == "Original.mlmodel")
    }

    @Test("A newer selection stays pending while the saved basename reflects the completed save")
    func preservesSelectionDuringSaving() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let first = root.appendingPathComponent("First.mlmodel")
      let second = root.appendingPathComponent("Second.mlmodel")
      try Data([1]).write(to: first)
      try Data([2]).write(to: second)
      let document = WorkspaceDocument()
      defer { document.close() }
      document.storeService.workspaceDefinition.videoComponents = [
        .with {
          $0.vfxSource = .with {
            $0.internalID = 7
            $0.displayName = "Camera"
            $0.deviceWidth = 1920
            $0.deviceHeight = 1080
          }
        }
      ]
      document.storeService.workspaceDefinition.visions = [
        .with {
          $0.ldtxSceneDetectorVision = .with {
            $0.internalID = 5
            $0.displayName = "Classifier"
            $0.videoComponentInternalID = 7
          }
        }
      ]
      let url = root.appendingPathComponent("Workspace.ldtxworkspace")
      try await saveWorkspaceDocument(document, to: url)
      document.storeService.modelURLs[5] = first
      let gate = DispatchSemaphore(value: 0)
      let handle = BackgroundSnapshotWriter(document: document, destination: url)
      defer { document.writeProbe.withLock { $0 = nil } }
      document.writeProbe.withLock { probe in
        probe = {
          DispatchQueue.main.async {
            MainActor.assumeIsolated {
              handle.document.storeService.modelURLs[5] = second
              gate.signal()
            }
          }
          #expect(gate.wait(timeout: .now() + 5) == .success)
        }
      }
      try await saveWorkspaceDocument(document, to: url, operation: .saveOperation)
      document.writeProbe.withLock { $0 = nil }
      #expect(document.storeService.modelURLs[5] == .some(second))
      #expect(
        document.storeService.workspaceDefinition.visions[0].ldtxSceneDetectorVision
          .modelFileName == "First.mlmodel")
      #expect(
        try WorkspaceBundleReaderV4(at: url).read().definition.visions[0]
          .ldtxSceneDetectorVision.modelFileName == "First.mlmodel")
      #expect(document.isDocumentEdited)
      try await saveWorkspaceDocument(document, to: url, operation: .saveOperation)
      #expect(!document.storeService.modelURLs.keys.contains(5))
      #expect(
        document.storeService.workspaceDefinition.visions[0].ldtxSceneDetectorVision
          .modelFileName == "Second.mlmodel")
      #expect(!document.isDocumentEdited)
    }
  }
}
