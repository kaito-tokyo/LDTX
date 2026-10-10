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
  @Suite("UCT-1001: Validate before saving", .serialized)
  @MainActor
  struct UCT1001WorkspaceDocumentIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    @Test("UCT-1001.1: Validation aggregates problems before creating a package")
    func saveValidationAggregatesErrorsWithoutCreatingAPackage() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("Invalid.ldtxworkspace")
      let document = WorkspaceDocument()
      defer { document.close() }
      var validationErrors: [Error] = []
      document.editingState.inputValidationErrorHandler = { validationErrors.append($0) }
      document.storeService.workspaceDefinition.programs = [validationProgram(name: "Pattern")]
      document.storeService.workspaceDefinition.videoComponents = [validationPattern()]
      document.storeService.workspacePreferences.landscapeProgramPreferences[1, default: .init()]
        .videoLayerTransforms[2] = validationTransform(
          x: .with {
            $0.num = 2
            $0.den = 1
          })
      document.storeService.workspacePreferences.portraitProgramPreferences[1, default: .init()]
        .videoLayerTransforms[2] = validationTransform(
          x: .with {
            $0.num = 2
            $0.den = 1
          })
      do {
        try await saveWorkspaceDocument(document, to: url)
        Issue.record("Expected validation failure")
      } catch {
        #expect((error as NSError).code == CocoaError.userCancelled.rawValue)
      }
      let validationError = try #require(validationErrors.first as? WorkspaceSaveValidationError)
      #expect(validationError.messages.count == 3)
      #expect(validationError.failureReason?.contains("Landscape") == true)
      #expect(validationError.failureReason?.contains("Portrait") == true)
      #expect(validationError.failureReason?.contains("Pattern") == true)
      #expect(document.storeService.workspaceDefinition.displayName == "Untitled")
      #expect(document.fileURL == nil)
      #expect(document.isDocumentEdited)
      #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("UCT-1001.2: A corrected Workspace saves retained detached preferences")
    func invalidSavePreservesFilesAndCorrectionRoundTripsDetachedPreferences() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("Validated.ldtxworkspace")
      let document = WorkspaceDocument()
      defer { document.close() }
      document.storeService.workspaceDefinition.programs = [validationProgram(name: "Main")]
      document.storeService.workspaceDefinition.videoComponents = [validationPattern()]
      try await saveWorkspaceDocument(document, to: url)
      let before = try Data(contentsOf: url.appendingPathComponent("preferences.pb"))
      document.storeService.workspacePreferences.landscapeProgramPreferences[1, default: .init()]
        .videoLayerTransforms[2] = validationTransform(
          x: .with {
            $0.num = 2
            $0.den = 1
          })
      do {
        try await saveWorkspaceDocument(document, to: url, operation: .saveOperation)
        Issue.record("Expected validation failure")
      } catch {
        #expect((error as NSError).code == CocoaError.userCancelled.rawValue)
      }
      #expect(try Data(contentsOf: url.appendingPathComponent("preferences.pb")) == before)
      #expect(document.isDocumentEdited)
      document.storeService.workspacePreferences.landscapeProgramPreferences[1, default: .init()]
        .videoLayerTransforms[2] = validationTransform(
          x: .with {
            $0.num = 1
            $0.den = 2
          },
          scale: .with {
            $0.num = 1
            $0.den = 1
          })
      document.storeService.workspacePreferences.landscapeProgramPreferences[1, default: .init()]
        .videoLayerHidden[2] = true
      try await saveWorkspaceDocument(document, to: url, operation: .saveOperation)
      let reopened = try WorkspaceDocument(contentsOf: url, ofType: "tokyo.kaito.ldtx.workspace")
      defer { reopened.close() }
      #expect(
        reopened.storeService.workspacePreferences == document.storeService.workspacePreferences)
      #expect(
        (reopened.storeService.workspacePreferences.landscapeProgramPreferences[1]?
          .videoLayerInternalIds
          ?? []).isEmpty)
      #expect(!document.isDocumentEdited)
    }

    @Test("UCT-1001.3: The Save action reports aggregated validation without an error sheet")
    func saveActionReportsValidationWithoutSheet() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let document = WorkspaceDocument()
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      document.addWindowController(NSWindowController(window: window))
      defer {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.orderOut(nil)
        document.close()
      }
      let url = root.appendingPathComponent("ValidationSheet.ldtxworkspace")
      try await saveWorkspaceDocument(document, to: url)
      document.storeService.workspacePreferences.landscapeProgramPreferences[99] = .init()
      document.storeService.workspacePreferences.portraitProgramPreferences[100] = .init()
      var errors: [Error] = []
      document.editingState.inputValidationErrorHandler = { errors.append($0) }
      window.orderFront(nil)
      document.save(nil)
      for _ in 0..<100 where errors.isEmpty {
        try await Task.sleep(for: .milliseconds(20))
      }
      let error = try #require(errors.first as? WorkspaceSaveValidationError)
      #expect(errors.count == 1)
      #expect(window.attachedSheet == nil)
      let messages = error.messages.joined(separator: "\n")
      #expect(messages.contains("Landscape"))
      #expect(messages.contains("Portrait"))
      #expect(messages.contains("99"))
      #expect(messages.contains("100"))
      await Task.yield()
    }

    @Test("UCT-1001.4: Background save validates its captured snapshot before writing")
    func backgroundSnapshotValidationPrecedesIO() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let document = WorkspaceDocument()
      defer { document.close() }
      let url = root.appendingPathComponent("Invalid.ldtxworkspace")
      document.storeService.workspacePreferences.audioChannelGainsDecibels[99] = .with {
        $0.num = 0
        $0.den = 1
      }
      #expect(
        document.canAsynchronouslyWrite(
          to: url, ofType: "tokyo.kaito.ldtx.workspace", for: .saveAsOperation))
      document.storeService.workspacePreferences.audioChannelGainsDecibels.removeValue(forKey: 99)
      let writer = BackgroundSnapshotWriter(document: document, destination: url)
      do {
        try await Task.detached { try writer.write() }.value
        Issue.record("Expected snapshot validation failure")
      } catch let error as WorkspaceSaveValidationError {
        #expect(error.messages.count == 1)
        #expect(error.failureReason?.contains("99") == true)
      }
      #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    private func validationProgram(name: String) -> Ldtx_Workspace_V4_ProgramDefinition {
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 1
      program.displayName = name
      return program
    }

    private func validationPattern() -> Ldtx_Workspace_V4_VideoComponentWrapper {
      var component = Ldtx_Workspace_V4_VideoComponentWrapper()
      component.testPattern.internalID = 2
      component.testPattern.displayName = "Pattern"
      return component
    }

    private func validationTransform(
      x: Ldtx_Workspace_V4_Rational32 = .with {
        $0.num = 0
        $0.den = 1
      },
      scale: Ldtx_Workspace_V4_Rational32 = .with {
        $0.num = 0
        $0.den = 1
      }
    )
      -> Ldtx_Workspace_V4_BasicTransform
    {
      var transform = Ldtx_Workspace_V4_BasicTransform()
      transform.translationX = x
      transform.scaleX = .init(value: scale)
      return transform
    }

  }
}
