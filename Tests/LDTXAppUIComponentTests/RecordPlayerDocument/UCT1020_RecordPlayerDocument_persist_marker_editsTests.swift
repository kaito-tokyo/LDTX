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
  @Suite("UCT-1020: persist-marker-edits", .serialized)
  @MainActor
  struct UCT1020RecordPlayerDocumentIntegrationTestSuite {
    private static var controller: NSDocumentController {
      UIComponentTestEnvironment.documentController
    }
    init() { _ = Self.controller }

    @Test("UCT-1020.1: Marker additions await Save and deletion is immediate")
    func additionsWaitForSaveAndDeletionIsImmediate() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let document = try openRecordingTestDocument(url)
      defer { document.close() }
      document.makeWindowControllers()
      let model = try #require(document.model)
      let player = AVPlayer()
      model.player = player
      model.selectedCanvas = .portrait
      try document.createMarker(note: "Saved", at: .zero)
      #expect(document.isDocumentEdited)
      #expect(try RecordingMarkerStore(recordingDirectoryURL: url).markers().isEmpty)
      try await saveRecordingTestDocument(document, to: url)
      #expect(!document.isDocumentEdited)
      try document.deleteMarker(try #require(document.markers.first))
      #expect(
        !document.validateUserInterfaceItem(
          NSMenuItem(
            title: "Revert", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")))
      #expect(try RecordingMarkerStore(recordingDirectoryURL: url).markers().isEmpty)
      #expect(document.markers.isEmpty)
      #expect(!document.isDocumentEdited)
      #expect(model.player === player)
      #expect(model.selectedCanvas == .portrait)
      #expect(
        document.windowControllers.first?.window?.restorationClass
          === UIComponentDocumentController.self)
      document.close()
      #expect(model.player == nil)
    }

    @Test("UCT-1020.2: Observers follow marker edits and disk synchronization")
    func markerObservationTracksAdditionSaveSyncAndImmediateDeletion() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let document = try openRecordingTestDocument(url)
      defer { document.close() }
      let notifications = OSAllocatedUnfairLock(initialState: 0)
      func observeMarkers() {
        withObservationTracking {
          _ = document.markers
        } onChange: {
          notifications.withLock { $0 += 1 }
        }
      }
      observeMarkers()
      try document.createMarker(note: "Saved", at: .zero)
      #expect(notifications.withLock { $0 } == 1)
      try await saveRecordingTestDocument(document, to: url)
      #expect(!document.isDocumentEdited)
      _ = try RecordingMarkerStore(recordingDirectoryURL: url).createMarker(
        at: CMTime(seconds: 1, preferredTimescale: 1000), note: "External")
      observeMarkers()
      try await saveRecordingTestDocument(document, to: url)
      #expect(notifications.withLock { $0 } == 2)
      #expect(document.markers.map(\.note) == ["Saved", "External"])
      #expect(!document.isDocumentEdited)
      observeMarkers()
      try document.deleteMarker(try #require(document.markers.first))
      #expect(notifications.withLock { $0 } == 3)
      #expect(!document.isDocumentEdited)
      #expect(
        try RecordingMarkerStore(recordingDirectoryURL: url).markers().map(\.note) == ["External"])
    }

    @Test("UCT-1020.3: Canonical collisions preserve filenames and pending edits")
    func canonicalCollisionOverwritesExistingNameAndDeletionKeepsPendingEdits() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let directory = url.appendingPathComponent("Markers")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      let name = "0-00-00.000.TXT"
      try Data("Old\n".utf8).write(to: directory.appendingPathComponent(name))
      let document = try openRecordingTestDocument(url)
      defer { document.close() }
      try document.createMarker(note: "New", at: CMTime(value: 1, timescale: 10000))
      #expect(document.markers.count == 1)
      #expect(document.markers.first?.fileName == name)
      try await saveRecordingTestDocument(document, to: url)
      try document.createMarker(note: "Pending", at: CMTime(seconds: 1, preferredTimescale: 1000))
      try document.deleteMarker(try #require(document.markers.first))
      #expect(document.isDocumentEdited)
      #expect(document.markers.map(\.note) == ["Pending"])
      #expect(try RecordingMarkerStore(recordingDirectoryURL: url).markers().isEmpty)
      document.close()
      let reopened = try openRecordingTestDocument(url)
      defer { reopened.close() }
      #expect(reopened.markers.isEmpty)
    }

    @Test("UCT-1020.4: A failed reread retains edits for retry")
    func rereadFailureKeepsPendingEditsAndRetrySynchronizesDiskOnlyMarkers() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let document = try openRecordingTestDocument(url)
      defer { document.close() }
      try document.createMarker(note: "Pending", at: .zero)
      let directory = url.appendingPathComponent("Markers")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      let unreadable = directory.appendingPathComponent("00-00-01.000.txt")
      try Data([0xff]).write(to: unreadable)
      do {
        try await saveRecordingTestDocument(document, to: url)
        Issue.record("Expected reread failure")
      } catch {}
      #expect(document.isDocumentEdited)
      #expect(document.markers.map(\.note) == ["Pending"])
      #expect(
        try String(
          contentsOf: directory.appendingPathComponent("00-00-00.000.txt"), encoding: .utf8)
          == "Pending\n")
      try Data("External\n".utf8).write(to: unreadable)
      try await saveRecordingTestDocument(document, to: url)
      #expect(!document.isDocumentEdited)
      #expect(document.markers.map(\.note) == ["Pending", "External"])
    }

    @Test("UCT-1020.5: A failed deletion retains a clean marker list")
    func deletionFailureRetainsMarkerAndDoesNotMakeCleanDocumentDirty() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let document = try openRecordingTestDocument(url)
      defer { document.close() }
      try document.createMarker(note: "Saved", at: .zero)
      try await saveRecordingTestDocument(document, to: url)
      let marker = try #require(document.markers.first)
      let markerURL = url.appendingPathComponent("Markers").appendingPathComponent(marker.fileName)
      try FileManager.default.removeItem(at: markerURL)
      try FileManager.default.createDirectory(at: markerURL, withIntermediateDirectories: false)
      #expect(throws: RecordingMarkerError.invalidMarkerFile) { try document.deleteMarker(marker) }
      #expect(document.markers == [marker])
      #expect(!document.isDocumentEdited)
    }

    @Test("UCT-1020.6: Hosted panes observe only their own recording markers")
    func hostedPanesObserveOneDocumentWithoutSharingOtherDocuments() async throws {
      let firstURL = try makeRecordingTestPackage()
      let secondURL = try makeRecordingTestPackage()
      defer {
        try? FileManager.default.removeItem(at: firstURL)
        try? FileManager.default.removeItem(at: secondURL)
      }
      let first = try openRecordingTestDocument(firstURL)
      let second = try openRecordingTestDocument(secondURL)
      defer {
        first.close()
        second.close()
      }
      let firstReference = DocumentReference(first)
      let secondReference = DocumentReference(second)
      let firstProbe = MarkerPaneProbe()
      let secondProbe = MarkerPaneProbe()
      let otherProbe = MarkerPaneProbe()
      let windows = [
        hostRecordingMarkerProbe(firstReference, probe: firstProbe),
        hostRecordingMarkerProbe(firstReference, probe: secondProbe),
        hostRecordingMarkerProbe(secondReference, probe: otherProbe),
      ]
      defer { for window in windows { window.close() } }
      for _ in 0..<100 where !firstProbe.appeared || !secondProbe.appeared || !otherProbe.appeared {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(firstProbe.appeared && secondProbe.appeared && otherProbe.appeared)
      try first.createMarker(note: "Shared", at: .zero)
      for _ in 0..<100 where firstProbe.notes != ["Shared"] || secondProbe.notes != ["Shared"] {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(firstProbe.notes == ["Shared"])
      #expect(secondProbe.notes == ["Shared"])
      #expect(otherProbe.notes.isEmpty)
      try await saveRecordingTestDocument(first, to: firstURL)
      try first.deleteMarker(try #require(first.markers.first))
      for _ in 0..<100 where !firstProbe.notes.isEmpty || !secondProbe.notes.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(firstProbe.notes.isEmpty && secondProbe.notes.isEmpty)
      try await saveRecordingTestDocument(first, to: firstURL)
      #expect(firstProbe.notes.isEmpty && secondProbe.notes.isEmpty)
      #expect(otherProbe.notes.isEmpty)
    }

    @Test("UCT-1020.7: Failed save and revert preserve pending markers")
    func failedSaveAndRevertKeepEditsAndUnsupportedActionsAreDisabled() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let document = try openRecordingTestDocument(url)
      defer { document.close() }
      try document.createMarker(note: "Pending", at: .zero)
      try Data().write(to: url.appendingPathComponent(".shield.json"))
      do {
        try await saveRecordingTestDocument(document, to: url)
        Issue.record("Expected save failure")
      } catch {}
      #expect(document.isDocumentEdited)
      #expect(document.markers.map(\.note) == ["Pending"])
      let invalid = url.appendingPathComponent("missing")
      #expect(throws: (any Error).self) {
        try document.revert(toContentsOf: invalid, ofType: RecordPlayerDocument.typeName)
      }
      #expect(document.markers.map(\.note) == ["Pending"])
      #expect(document.isDocumentEdited)
      do {
        try await saveRecordingTestDocument(document, to: invalid, operation: .saveAsOperation)
        Issue.record("Expected Save As failure")
      } catch {}
      #expect(document.autosavingFileType == nil)
      for action in [
        #selector(NSDocument.revertToSaved(_:)),
        #selector(NSDocument.saveAs(_:)), #selector(NSDocument.saveTo(_:)),
        #selector(NSDocument.duplicate(_:)),
        #selector(NSDocument.rename(_:)), #selector(NSDocument.move(_:)),
        #selector(NSDocument.moveToUbiquityContainer(_:)),
      ] {
        #expect(
          !document.validateUserInterfaceItem(
            NSMenuItem(title: "", action: action, keyEquivalent: "")))
      }
      #expect(document.fileURL == url)
    }
  }
}
