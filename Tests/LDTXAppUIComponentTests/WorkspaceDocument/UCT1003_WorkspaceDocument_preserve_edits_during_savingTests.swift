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
  @Suite("UCT-1003: preserve-edits-during-saving", .serialized)
  @MainActor
  struct UCT1003WorkspaceDocumentIntegrationTestSuite {
    private static var controller: NSDocumentController {
      UIComponentTestEnvironment.documentController
    }
    init() { _ = Self.controller }

    @Test("UCT-1003.1: Edits synchronously update AppKit document change state")
    func tracksChangesSynchronouslyAndUsesAppKitSaveState() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let document = WorkspaceDocument()
      let destination = root.appendingPathComponent("Saved.ldtxworkspace")
      #expect(document.fileURL == nil)
      document.storeService.definition.displayName = "Saved"
      #expect(document.isDocumentEdited)
      try await saveWorkspaceDocument(document, to: destination)
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

    @Test("UCT-1003.2: A queued save includes edits made before it starts")
    func editsBeforeQueuedSaveStartsAreIncluded() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let destination = root.appendingPathComponent("Snapshot.ldtxworkspace")
      let document = WorkspaceDocument()
      document.storeService.definition.displayName = "Snapshot"
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        document.save(to: destination, ofType: "tokyo.kaito.ldtx.workspace", for: .saveAsOperation)
        {
          error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
        document.storeService.definition.displayName = "Later edit"
      }
      #expect(
        try WorkspaceBundleReaderV4(at: destination).read().definition.displayName == "Later edit")
      #expect(document.storeService.definition.displayName == "Later edit")
      #expect(!document.isDocumentEdited)
      document.close()
    }

    @Test("UCT-1003.3: A captured background snapshot excludes later edits")
    func backgroundSnapshotDoesNotIncludeLaterEdits() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let destination = root.appendingPathComponent("Snapshot.ldtxworkspace")
      let document = WorkspaceDocument()
      document.storeService.definition.displayName = "Snapshot"
      let token = document.changeCountToken(for: .saveOperation)
      #expect(
        document.canAsynchronouslyWrite(
          to: destination, ofType: "tokyo.kaito.ldtx.workspace", for: .saveAsOperation))
      document.storeService.definition.displayName = "Later edit"
      let writer = BackgroundSnapshotWriter(document: document, destination: destination)
      try await Task.detached { try writer.write() }.value
      document.updateChangeCount(withToken: token, for: .saveOperation)
      #expect(
        try WorkspaceBundleReaderV4(at: destination).read().definition.displayName == "Snapshot")
      #expect(document.isDocumentEdited)
      document.close()
    }

    @Test("UCT-1003.4: Unsupported copy actions are disabled and save failures retain edits")
    func copyActionsAreDisabledAndSaveFailureKeepsEdits() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let document = WorkspaceDocument()
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 101
      program.displayName = "Main"
      document.storeService.definition.programs = [program]
      var audio = Ldtx_Workspace_V4_AudioInputDevice()
      audio.internalID = 102
      audio.displayName = "Input"
      document.storeService.definition.audioDevices = [audio]
      defer { document.close() }
      for action in [
        #selector(NSDocument.saveAs(_:)), #selector(NSDocument.saveTo(_:)),
        #selector(NSDocument.duplicate(_:)),
      ] {
        #expect(
          !document.validateUserInterfaceItem(
            NSMenuItem(title: "", action: action, keyEquivalent: "")))
      }
      let url = root.appendingPathComponent("Workspace.ldtxworkspace")
      try await saveWorkspaceDocument(document, to: url)
      document.writeProbe.withLock { $0 = { throw CocoaError(.fileWriteNoPermission) } }
      defer { document.writeProbe.withLock { $0 = nil } }
      document.storeService.definition.displayName = "Pending"
      do {
        try await saveWorkspaceDocument(document, to: url, operation: .saveOperation)
        Issue.record("Expected partial save failure")
      } catch {}
      #expect(document.isDocumentEdited)
      #expect(document.storeService.definition.displayName == "Pending")
      document.writeProbe.withLock { $0 = nil }
      try await saveWorkspaceDocument(document, to: url, operation: .saveOperation)
      #expect(!document.isDocumentEdited)
      document.storeService.isOutputActive = true
      let fixedDefinition = document.storeService.definition
      document.storeService.definition.displayName = "Rejected during output"
      document.storeService.preferences.landscapeProgramPreferences[101, default: .init()]
        .audioMasterVolumeDecibels = .with {
          $0.numerator = -8
          $0.denominator = 1
        }
      #expect(document.storeService.setAudioChannelGain(-12, forAudioInputDeviceInternalID: 102))
      try await saveWorkspaceDocument(document, to: url, operation: .saveOperation)
      let savedOutput = try WorkspaceBundleReaderV4(at: url).read()
      #expect(
        savedOutput.preferences.landscapeProgramPreferences[101]?.audioMasterVolumeDecibels
          == Ldtx_Workspace_V4_Rational32.with {
            $0.numerator = -8
            $0.denominator = 1
          })
      #expect(
        savedOutput.preferences.audioChannelGainsDecibels[102]
          == Ldtx_Workspace_V4_Rational32.with {
            $0.numerator = -12
            $0.denominator = 1
          })
      #expect(savedOutput.definition == fixedDefinition)
      document.storeService.isOutputActive = false
    }

    @Test("UCT-1003.5: Editing continues while a background save is pending")
    func editsCanProceedWhileBackgroundSaveIsPaused() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let document = WorkspaceDocument()
      defer { document.close() }
      let url = root.appendingPathComponent("Workspace.ldtxworkspace")
      try await saveWorkspaceDocument(document, to: url)
      document.storeService.definition.displayName = "Snapshot"
      let gate = DispatchSemaphore(value: 0)
      let handle = BackgroundSnapshotWriter(document: document, destination: url)
      defer { document.writeProbe.withLock { $0 = nil } }
      document.writeProbe.withLock { probe in
        probe = {
          DispatchQueue.main.async {
            MainActor.assumeIsolated {
              handle.document.storeService.definition.displayName = "Later edit"
              gate.signal()
            }
          }
          // A bounded wait fails rather than hanging if interaction remains blocked.
          #expect(!Thread.isMainThread)
          #expect(gate.wait(timeout: .now() + 5) == .success)
        }
      }
      try await saveWorkspaceDocument(document, to: url, operation: .saveOperation)
      document.writeProbe.withLock { $0 = nil }
      #expect(document.storeService.definition.displayName == "Later edit")
      #expect(try WorkspaceBundleReaderV4(at: url).read().definition.displayName == "Snapshot")
      #expect(document.isDocumentEdited)
    }

  }
}
