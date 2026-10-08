// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import LDTXAppletSupport
import LDTXProtos
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletInterface
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
      var reportedErrors: [Error] = []
      document.storeService.errorHandler = { reportedErrors.append($0) }
      document.storeService.definition.programs = [validationProgram(name: "Pattern")]
      document.storeService.definition.videoComponents = [validationPattern()]
      document.storeService.preferences.landscapeProgramPreferences[1, default: .init()]
        .videoLayerTransforms[2] = validationTransform(
          x: .with {
            $0.numerator = 2
            $0.denominator = 1
          })
      document.storeService.preferences.portraitProgramPreferences[1, default: .init()]
        .videoLayerTransforms[2] = validationTransform(
          x: .with {
            $0.numerator = 2
            $0.denominator = 1
          })
      do {
        try await saveWorkspaceDocument(document, to: url)
        Issue.record("Expected validation failure")
      } catch let error as WorkspaceSaveValidationError {
        #expect(error.messages.count == 3)
        let alert = NSAlert(error: error)
        #expect(alert.informativeText.contains("Landscape"))
        #expect(alert.informativeText.contains("Portrait"))
        #expect(alert.informativeText.contains("Pattern"))
      }
      #expect(reportedErrors.isEmpty)
      #expect(document.storeService.definition.displayName == "Untitled")
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
      document.storeService.definition.programs = [validationProgram(name: "Main")]
      document.storeService.definition.videoComponents = [validationPattern()]
      try await saveWorkspaceDocument(document, to: url)
      let before = try Data(contentsOf: url.appendingPathComponent("preferences.pb"))
      document.storeService.preferences.landscapeProgramPreferences[1, default: .init()]
        .videoLayerTransforms[2] = validationTransform(
          x: .with {
            $0.numerator = 2
            $0.denominator = 1
          })
      do {
        try await saveWorkspaceDocument(document, to: url, operation: .saveOperation)
        Issue.record("Expected validation failure")
      } catch is WorkspaceSaveValidationError {}
      #expect(try Data(contentsOf: url.appendingPathComponent("preferences.pb")) == before)
      #expect(document.isDocumentEdited)
      document.storeService.preferences.landscapeProgramPreferences[1, default: .init()]
        .videoLayerTransforms[2] = validationTransform(
          x: .with {
            $0.numerator = 1
            $0.denominator = 2
          },
          scale: .with {
            $0.numerator = 1
            $0.denominator = 1
          })
      document.storeService.preferences.landscapeProgramPreferences[1, default: .init()]
        .videoLayerHidden[2] = true
      try await saveWorkspaceDocument(document, to: url, operation: .saveOperation)
      let reopened = try WorkspaceDocument(contentsOf: url, ofType: "tokyo.kaito.ldtx.workspace")
      defer { reopened.close() }
      #expect(reopened.storeService.preferences == document.storeService.preferences)
      #expect((reopened.storeService.preferences.landscapeProgramPreferences[1]?.videoLayerInternalIds ?? []).isEmpty)
      #expect(!document.isDocumentEdited)
    }

    @Test("UCT-1001.3: The Save action presents one aggregated validation sheet")
    func saveActionPresentsOneValidationSheet() async throws {
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
      document.storeService.preferences.landscapeProgramPreferences[99] = .init()
      document.storeService.preferences.portraitProgramPreferences[100] = .init()
      window.orderFront(nil)
      document.save(nil)
      for _ in 0..<100 where window.attachedSheet == nil {
        try await Task.sleep(for: .milliseconds(20))
      }
      let sheet = try #require(window.attachedSheet)
      func text(in view: NSView) -> [String] {
        (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap { text(in: $0) }
      }
      let messages = text(in: try #require(sheet.contentView)).joined(separator: "\n")
      #expect(messages.contains("Landscape"))
      #expect(messages.contains("Portrait"))
      #expect(messages.contains("99"))
      #expect(messages.contains("100"))
      window.endSheet(sheet)
      await Task.yield()
    }

    @Test("UCT-1001.4: Background save validates its captured snapshot before writing")
    func backgroundSnapshotValidationPrecedesIO() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let document = WorkspaceDocument()
      defer { document.close() }
      let url = root.appendingPathComponent("Invalid.ldtxworkspace")
      document.storeService.preferences.audioChannelGainsDecibels[99] = .with {
        $0.numerator = 0
        $0.denominator = 1
      }
      #expect(
        document.canAsynchronouslyWrite(
          to: url, ofType: "tokyo.kaito.ldtx.workspace", for: .saveAsOperation))
      document.storeService.preferences.audioChannelGainsDecibels.removeValue(forKey: 99)
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
        $0.numerator = 0
        $0.denominator = 1
      },
      scale: Ldtx_Workspace_V4_Rational32 = .with {
        $0.numerator = 0
        $0.denominator = 1
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
