// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AppKit
import LDTXAppletSupport
@testable import LDTXRecordPlayerApplet
import LDTXRecording
import LDTXWorkspaceAppletController
import Observation
import SwiftUI
import Testing
import os

extension AppUIComponentTestSuite {
  @Suite("UCT-1021: open-and-move-recordings", .serialized)
  @MainActor
  struct UCT1021RecordPlayerDocumentIntegrationTestSuite {
    private static var controller: NSDocumentController {
      UIComponentTestEnvironment.documentController
    }
    init() { _ = Self.controller }

    @Test("UCT-1021.1: Malformed optional markers do not block the player")
    func malformedOptionalMarkersAllowPlaybackButCannotBeOverwritten() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let markerURL = try RecordingMarkerStore(recordingDirectoryURL: url).createMarker(
        at: .zero, note: "Original")
      let malformed = Data([0xff, 0xfe])
      try malformed.write(to: markerURL)
      let document = try openRecordingTestDocument(url)
      defer { document.close() }
      document.makeWindowControllers()
      #expect(document.model != nil)
      #expect(document.markers.isEmpty)
      try document.createMarker(note: "Pending", at: CMTime(seconds: 1, preferredTimescale: 600))
      do {
        try await saveRecordingTestDocument(document, to: url)
        Issue.record("Unreadable optional markers must not be overwritten")
      } catch {}
      #expect(document.isDocumentEdited)
      #expect(try Data(contentsOf: markerURL) == malformed)
      #expect(throws: (any Error).self) {
        try document.revert(toContentsOf: url, ofType: RecordPlayerDocument.typeName)
      }
      #expect(document.markers.map(\.note) == ["Pending"])
      try Data("Repaired\n".utf8).write(to: markerURL)
      try document.revert(toContentsOf: url, ofType: RecordPlayerDocument.typeName)
      #expect(document.markers.map(\.note) == ["Repaired"])
      try document.createMarker(note: "New", at: CMTime(seconds: 1, preferredTimescale: 600))
      try await saveRecordingTestDocument(document, to: url)
      #expect(!document.isDocumentEdited)
    }

    @Test("UCT-1021.2: The registered recording alias supports opening and saving")
    func legacyRegisteredTypeStillOpensAndSavesMarkers() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      _ = Self.controller
      let document = try RecordPlayerDocument(
        contentsOf: url, ofType: RecordingPackageInfo.legacyTypeIdentifier)
      defer { document.close() }
      try document.createMarker(note: "Legacy association", at: .zero)
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        document.save(
          to: url, ofType: RecordingPackageInfo.legacyTypeIdentifier, for: .saveOperation
        ) { error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
      }
      #expect(!document.isDocumentEdited)
      #expect(
        try RecordingMarkerStore(recordingDirectoryURL: url).markers().map(\.note) == [
          "Legacy association"
        ])
    }

    @Test("UCT-1021.3: Recording Documents coexist with Workspace Documents")
    func standardControllerOwnsAndReusesRecordingAlongsideWorkspace() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let controller = Self.controller
      let workspace = try controller.makeUntitledDocument(ofType: "tokyo.kaito.ldtx.workspace")
      controller.addDocument(workspace)
      defer { workspace.close() }
      func open() async throws -> (NSDocument, Bool) {
        try await withCheckedThrowingContinuation { continuation in
          controller.openDocument(withContentsOf: url, display: false) {
            document, existing, error in
            if let error {
              continuation.resume(throwing: error)
            } else if let document {
              continuation.resume(returning: (document, existing))
            } else {
              continuation.resume(throwing: CocoaError(.fileReadUnknown))
            }
          }
        }
      }
      let (first, alreadyOpen) = try await open()
      defer { first.close() }
      let (second, reused) = try await open()
      #expect(first is RecordPlayerDocument)
      #expect(!alreadyOpen && reused)
      #expect(first === second)
      #expect(controller.documents.contains { $0 === first })
      #expect(controller.documents.contains { $0 === workspace })
    }

    @Test("UCT-1021.4: A moved recording preserves markers and loads its current URL")
    func movedRecordingSavesPendingMarkersAndLoadsCurrentURL() async throws {
      let original = try makeRecordingTestPackage()
      let moved = original.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("ldtxrecord")
      defer {
        try? FileManager.default.removeItem(at: original)
        try? FileManager.default.removeItem(at: moved)
      }
      _ = try RecordingMarkerStore(recordingDirectoryURL: original).createMarker(
        at: .zero, note: "Saved")
      let document = try openRecordingTestDocument(original)
      defer { document.close() }
      var loadedURLs: [URL] = []
      document.assetLoader = { url, _ in
        loadedURLs.append(url)
        return AVMutableComposition()
      }
      document.makeWindowControllers()
      let model = try #require(document.model)
      model.start()
      for _ in 0..<100 where model.isLoading { try await Task.sleep(for: .milliseconds(10)) }
      #expect(loadedURLs == [original])
      try document.createMarker(note: "Pending", at: CMTime(seconds: 1, preferredTimescale: 1000))
      let player = model.player
      try FileManager.default.moveItem(at: original, to: moved)
      document.presentedItemDidMove(to: moved)
      for _ in 0..<100 where document.fileURL != moved {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(document.fileURL == moved)
      #expect(model.player === player)
      #expect(document.markers.map(\.note) == ["Saved", "Pending"])
      model.availableCanvases = [.landscape, .portrait]
      model.selectCanvas(.portrait)
      for _ in 0..<100 where loadedURLs.count < 2 || model.isLoading {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(loadedURLs == [original, moved])
      #expect(document.markers.map(\.note) == ["Saved", "Pending"])
      try await saveRecordingTestDocument(document, to: moved)
      #expect(!document.isDocumentEdited)
      #expect(
        try RecordingMarkerStore(recordingDirectoryURL: moved).markers().map(\.note) == [
          "Saved", "Pending",
        ])
      try document.createMarker(note: "Keep", at: CMTime(seconds: 2, preferredTimescale: 1000))
      try Data().write(to: moved.appendingPathComponent(".shield.json"))
      do {
        try await saveRecordingTestDocument(document, to: moved)
        Issue.record("Expected active recording save failure")
      } catch {}
      #expect(document.isDocumentEdited)
      #expect(document.markers.map(\.note) == ["Saved", "Pending", "Keep"])
    }

    @Test("UCT-1021.5: The shared controller resolves both Document families")
    func sharedDocumentControllerResolvesBothDocumentFamilies() throws {
      let controller = UIComponentTestEnvironment.documentController
      #expect(NSDocumentController.shared === controller)
      #expect(
        controller.documentClass(forType: "tokyo.kaito.ldtx.workspace") === WorkspaceDocument.self)
      #expect(
        controller.documentClass(forType: RecordPlayerDocument.typeName)
          === RecordPlayerDocument.self
      )
      #expect(
        controller.documentClass(forType: RecordingPackageInfo.legacyTypeIdentifier)
          === RecordPlayerDocument.self)
      #expect(
        try controller.typeForContents(of: URL(fileURLWithPath: "/tmp/Test.ldtxworkspace"))
          == "tokyo.kaito.ldtx.workspace")
      #expect(
        try controller.typeForContents(of: URL(fileURLWithPath: "/tmp/Test.ldtxrecord"))
          == RecordPlayerDocument.typeName)
    }
  }
}
