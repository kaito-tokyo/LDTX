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
  @Suite("UCT-1004: restrict-edits-during-output", .serialized)
  @MainActor
  struct UCT1004WorkspaceDocumentIntegrationTestSuite {
    private static var controller: NSDocumentController {
      UIComponentTestEnvironment.documentController
    }
    init() { _ = Self.controller }

    @Test("UCT-1004.1: Output permits only layer permutations and saves the latest order")
    func outputAllowsOnlyLayerPermutationsAndPersistsLatestOrder() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let document = WorkspaceDocument()
      defer {
        document.storeService.isOutputActive = false
        document.close()
      }
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 101
      program.displayName = "Main"
      document.storeService.definition.programs = [program]
      document.storeService.definition.videoComponents = [1, 2, 3].map { id in
        var device = Ldtx_Workspace_V4_VfxSourceComponent()
        device.internalID = UInt64(id)
        device.displayName = "Camera \(id)"
        var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
        wrapper.vfxSource = device
        return wrapper
      }
      document.storeService.preferences.landscapeProgramPreferences[101] = .with { $0.videoLayerInternalIds = [1, 2, 3] }
      document.storeService.preferences.portraitProgramPreferences[101] = .with { $0.videoLayerInternalIds = [3, 2, 1] }
      let url = root.appendingPathComponent("Workspace.ldtxworkspace")
      try await saveWorkspaceDocument(document, to: url)
      document.storeService.isOutputActive = true
      let definition = document.storeService.definition
      let outputSettings = document.storeService.outputSettings
      try document.storeService.commitLayerOrder([3, 1, 2], programID: 101, target: .landscape)
      try document.storeService.commitLayerOrder([1, 3, 2], programID: 101, target: .portrait)
      #expect(document.isDocumentEdited)
      let reordered = document.storeService.preferences
      for rejected: [UInt64] in [[3, 1], [3, 1, 2, 4], [3, 1, 1]] {
        #expect(throws: WorkspaceSelectionError.self) {
          try document.storeService.commitLayerOrder(rejected, programID: 101, target: .landscape)
        }
        #expect(document.storeService.preferences == reordered)
      }
      document.storeService.definition.displayName = "Forbidden"
      document.storeService.definition.programs.removeAll()
      #expect(document.storeService.definition == definition)
      document.storeService.outputSettings.recordingEnabled.toggle()
      #expect(document.storeService.outputSettings == outputSettings)
      try document.storeService.commitLayerOrder([2, 3, 1], programID: 101, target: .landscape)
      let latest = document.storeService.preferences
      try await saveWorkspaceDocument(document, to: url, operation: .saveOperation)
      let persisted = try WorkspaceBundleReaderV4(at: url).read()
      #expect(persisted.definition == definition)
      #expect(persisted.preferences == latest)
      #expect(persisted.outputSettings == outputSettings)
      document.storeService.isOutputActive = false
      let reopened = WorkspaceDocument()
      defer { reopened.close() }
      try reopened.read(from: url, ofType: "tokyo.kaito.ldtx.workspace")
      #expect(reopened.storeService.definition == definition)
      #expect(reopened.storeService.preferences == latest)
      #expect(reopened.storeService.outputSettings == outputSettings)
    }

    @Test("UCT-1004.2: Starting output does not save pending edits")
    func startingOutputDoesNotSavePendingModelEdits() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("Output.ldtxworkspace")
      let document = WorkspaceDocument()
      defer { document.close() }
      try await saveWorkspaceDocument(document, to: url)
      let definition = try Data(contentsOf: url.appendingPathComponent("definition.pb"))
      let preferences = try Data(contentsOf: url.appendingPathComponent("preferences.pb"))
      document.makeWindowControllers()
      let controller = try #require(document.windowControllers.first as? WorkspaceWindowController)
      document.storeService.definition.displayName = "Pending"
      // No Program/output is enabled, so this exercises the entry without media I/O.
      try await controller.startOutput()
      #expect(document.isDocumentEdited)
      #expect(document.storeService.definition.displayName == "Pending")
      #expect(try Data(contentsOf: url.appendingPathComponent("definition.pb")) == definition)
      #expect(try Data(contentsOf: url.appendingPathComponent("preferences.pb")) == preferences)
      await document.shutdown()
    }

    @Test("UCT-1004.3: Output freezes definition while preferences remain editable")
    func outputFreezesDefinitionButTracksPreferences() {
      let document = WorkspaceDocument()
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 101
      program.displayName = "Main"
      document.storeService.definition.programs = [program]
      document.updateChangeCount(.changeCleared)
      let original = document.storeService.definition
      document.storeService.isOutputActive = true
      document.storeService.definition.displayName = "Rejected"
      #expect(document.storeService.definition == original)
      #expect(!document.isDocumentEdited)
      document.storeService.preferences.landscapeProgramPreferences[101, default: .init()]
        .audioMasterVolumeDecibels = .with {
          $0.numerator = -6
          $0.denominator = 1
        }
      #expect(document.isDocumentEdited)
    }

    @Test("UCT-1004.4: Output disables Save As and Revert")
    func outputDisablesSaveAsAndRevert() {
      let document = WorkspaceDocument()
      document.storeService.isOutputActive = true
      let saveAs = NSMenuItem(
        title: "Save As", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "")
      let revert = NSMenuItem(
        title: "Revert", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
      #expect(!document.validateUserInterfaceItem(saveAs))
      #expect(!document.validateUserInterfaceItem(revert))
    }
  }
}
