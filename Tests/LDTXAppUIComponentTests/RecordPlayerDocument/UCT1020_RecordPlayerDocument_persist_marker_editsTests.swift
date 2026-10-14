// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation
import LDTXRecordBundleFormat
@testable import LDTXRecordPlayerApplet
import LDTXRecording
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1020: URL Document marker persistence", .serialized)
  @MainActor
  struct UCT1020RecordPlayerDocumentIntegrationTestSuite {
    @Test("Saving markers rejects an active recording without changing its files")
    func rejectsActiveRecordingSave() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      try FileManager.default.removeItem(
        at: url.appendingPathComponent(RecordingPackage.finalizedMarkerFileName))
      let document = try await openRecordingTestDocument(url)
      try document.createMarker(note: "Pending", at: .zero)
      await #expect(throws: (any Error).self) {
        try await saveRecordingTestDocument(document, to: url)
      }
      #expect(try RecordingMarkerStore(recordingDirectoryURL: url).markers().isEmpty)
      #expect(document.markers.map(\.note) == ["Pending"])
    }

    @Test("Deleting a marker resolves the filename adopted during an earlier save")
    func deletesReconciledDiskFilename() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let document = try await openRecordingTestDocument(url)
      try document.createMarker(note: "Local", at: .zero)
      let staleName = try #require(document.markers.first).fileName
      let directory = url.appendingPathComponent("Markers")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let diskName = "00-00-00.000.TXT"
      try Data("External\n".utf8).write(to: directory.appendingPathComponent(diskName))
      _ = try RecordingMarkerStore(recordingDirectoryURL: url).createMarker(
        at: CMTime(value: 1, timescale: 1), note: "Unrelated")
      try await saveRecordingTestDocument(document, to: url)
      #expect(document.markers.first?.fileName == staleName)
      #expect(
        try String(contentsOf: directory.appendingPathComponent(diskName), encoding: .utf8)
          == "Local\n")
      try document.deleteMarker(try #require(document.markers.first))
      try await saveRecordingTestDocument(document, to: url)
      #expect(
        !FileManager.default.fileExists(atPath: directory.appendingPathComponent(diskName).path))
      #expect(
        try RecordingMarkerStore(recordingDirectoryURL: url).markers().map(\.note) == ["Unrelated"])
    }

    @Test("Successful deletion is acknowledged and does not delete an external recreation")
    func committedDeletionDoesNotRepeat() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let document = try await openRecordingTestDocument(url)
      try document.createMarker(note: "Original", at: .zero)
      try await saveRecordingTestDocument(document, to: url)
      let undo = UndoManager()
      undo.groupsByEvent = false
      undo.beginUndoGrouping()
      try document.deleteMarker(try #require(document.markers.first), undoManager: undo)
      undo.endUndoGrouping()
      let deletion = try await document.snapshot(
        contentType: RecordPlayerDocument.readableContentTypes[0])
      func write(
        _ snapshot: RecordPlayerDocument.Writer.Snapshot,
        previous: RecordPlayerDocument.Writer.Snapshot?
      ) async throws {
        let manager = ProgressManager(totalCount: 1)
        try await RecordPlayerDocument.Writer().write(
          snapshot: snapshot, to: url, previous: previous,
          progress: manager.subprogress(assigningCount: 1))
      }
      try await write(deletion, previous: nil)
      _ = try RecordingMarkerStore(recordingDirectoryURL: url).createMarker(
        at: .zero, note: "External")
      let next = try await document.snapshot(
        contentType: RecordPlayerDocument.readableContentTypes[0])
      try await write(next, previous: deletion)
      #expect(
        try RecordingMarkerStore(recordingDirectoryURL: url).markers().map(\.note) == ["External"])
      undo.undo()
      undo.redo()
      let repeated = try await document.snapshot(
        contentType: RecordPlayerDocument.readableContentTypes[0])
      try await write(repeated, previous: next)
      #expect(try RecordingMarkerStore(recordingDirectoryURL: url).markers().isEmpty)
    }
    @Test("The writer saves only markers and preserves media and unrelated files")
    func markerOnlyWrite() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let media = url.appendingPathComponent("main.mp4")
      let mediaBytes = Data([1, 2, 3, 4])
      try mediaBytes.write(to: media)
      let extra = url.appendingPathComponent("Notes.txt")
      try Data("Keep".utf8).write(to: extra)
      let document = try await openRecordingTestDocument(url)
      try document.createMarker(note: "Saved", at: .zero)
      #expect(try RecordingMarkerStore(recordingDirectoryURL: url).markers().isEmpty)
      try await saveRecordingTestDocument(document, to: url)
      #expect(try Data(contentsOf: media) == mediaBytes)
      #expect(try String(contentsOf: extra, encoding: .utf8) == "Keep")
      let reopened = try await openRecordingTestDocument(url)
      #expect(reopened.markers.map(\.note) == ["Saved"])
      try document.deleteMarker(try #require(document.markers.first))
      #expect(document.markers.isEmpty)
      #expect(
        try RecordingMarkerStore(recordingDirectoryURL: url).markers().map(\.note) == ["Saved"])
      try await saveRecordingTestDocument(document, to: url)
      #expect(try RecordingMarkerStore(recordingDirectoryURL: url).markers().isEmpty)
    }

    @Test("Marker edits register Undo and Redo")
    func markerUndoRedo() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let document = try await openRecordingTestDocument(url)
      let undo = UndoManager()
      undo.groupsByEvent = false
      undo.beginUndoGrouping()
      try document.createMarker(note: "Original", at: .zero, undoManager: undo)
      undo.endUndoGrouping()
      undo.beginUndoGrouping()
      try document.createMarker(note: "Updated", at: .zero, undoManager: undo)
      undo.endUndoGrouping()
      undo.undo()
      #expect(document.markers.map(\.note) == ["Original"])
      undo.redo()
      #expect(document.markers.map(\.note) == ["Updated"])
      undo.removeAllActions()
    }

    @Test("Save failure and unsupported destinations preserve editing state")
    func failedWritePreservesMarkers() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let document = try await openRecordingTestDocument(url)
      try document.createMarker(note: "Pending", at: .zero)
      try Data().write(to: url.appendingPathComponent("Markers"))
      await #expect(throws: (any Error).self) {
        try await saveRecordingTestDocument(document, to: url)
      }
      #expect(document.markers.map(\.note) == ["Pending"])
      await #expect(throws: (any Error).self) {
        try await saveRecordingTestDocument(document, to: url.appendingPathComponent("Other"))
      }
      #expect(document.fileURL == url)
    }

    @Test("Safe saving writes markers to the framework's staging copy")
    func writesStagingCopy() async throws {
      let url = try makeRecordingTestPackage()
      let staging = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
      defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: staging)
      }
      let document = try await openRecordingTestDocument(url)
      try document.createMarker(note: "Staged", at: .zero)
      try FileManager.default.copyItem(at: url, to: staging)
      try await saveRecordingTestDocument(document, to: staging)
      #expect(
        try RecordingMarkerStore(recordingDirectoryURL: staging).markers().map(\.note) == ["Staged"]
      )
      #expect(try RecordingMarkerStore(recordingDirectoryURL: url).markers().isEmpty)
      #expect(
        FileManager.default.fileExists(atPath: staging.appendingPathComponent("main.mp4").path))
    }

    @Test("Canonical collisions preserve the original filename")
    func canonicalCollision() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let directory = url.appendingPathComponent("Markers")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      let name = "0-00-00.000.TXT"
      try Data("Old\n".utf8).write(to: directory.appendingPathComponent(name))
      let document = try await openRecordingTestDocument(url)
      try document.createMarker(note: "New", at: CMTime(value: 1, timescale: 10000))
      #expect(document.markers.first?.fileName == name)
      try await saveRecordingTestDocument(document, to: url)
      #expect(
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) == "New\n")
    }

    @Test("External reload preserves edits made since the previous snapshot")
    func mergeReloadWithPendingEdits() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let previous = try await readRecordingTestSnapshot(url)
      let document = RecordPlayerDocument(fileURL: url)
      try await document.apply(snapshot: previous, previous: nil)
      try document.createMarker(note: "Pending", at: .zero)
      _ = try RecordingMarkerStore(recordingDirectoryURL: url).createMarker(
        at: CMTime(seconds: 1, preferredTimescale: 1000), note: "External")
      try await document.apply(snapshot: readRecordingTestSnapshot(url), previous: previous)
      #expect(document.markers.map(\.note) == ["Pending", "External"])
    }

    @Test("Failed deletion save preserves pending removal and can be undone")
    func failedDeletion() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let document = try await openRecordingTestDocument(url)
      try document.createMarker(note: "Saved", at: .zero)
      try await saveRecordingTestDocument(document, to: url)
      let marker = try #require(document.markers.first)
      let path = url.appendingPathComponent("Markers").appendingPathComponent(marker.fileName)
      try FileManager.default.removeItem(at: path)
      try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
      let undo = UndoManager()
      undo.groupsByEvent = false
      undo.beginUndoGrouping()
      try document.deleteMarker(marker, undoManager: undo)
      undo.endUndoGrouping()
      #expect(document.markers.isEmpty)
      await #expect(throws: RecordingMarkerError.invalidMarkerFile) {
        try await saveRecordingTestDocument(document, to: url)
      }
      #expect(document.markers.isEmpty)
      undo.undo()
      #expect(document.markers == [marker])
      undo.removeAllActions()
    }

    @Test("Deletion participates in edit Undo and Redo before and after saving")
    func deletionUndoRedoAndPersistence() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let document = try await openRecordingTestDocument(url)
      try document.createMarker(note: "Original", at: .zero)
      try await saveRecordingTestDocument(document, to: url)
      let undo = UndoManager()
      undo.groupsByEvent = false
      defer { undo.removeAllActions() }
      undo.beginUndoGrouping()
      try document.createMarker(note: "Updated", at: .zero, undoManager: undo)
      undo.endUndoGrouping()
      undo.beginUndoGrouping()
      try document.deleteMarker(try #require(document.markers.first), undoManager: undo)
      undo.endUndoGrouping()
      #expect(document.markers.isEmpty)
      #expect(
        try RecordingMarkerStore(recordingDirectoryURL: url).markers().map(\.note) == ["Original"])
      undo.undo()
      #expect(document.markers.map(\.note) == ["Updated"])
      undo.undo()
      #expect(document.markers.map(\.note) == ["Original"])
      undo.redo()
      #expect(document.markers.map(\.note) == ["Updated"])
      undo.redo()
      #expect(document.markers.isEmpty)
      try await saveRecordingTestDocument(document, to: url)
      #expect(try RecordingMarkerStore(recordingDirectoryURL: url).markers().isEmpty)
      undo.undo()
      #expect(document.markers.map(\.note) == ["Updated"])
      try await saveRecordingTestDocument(document, to: url)
      #expect(
        try RecordingMarkerStore(recordingDirectoryURL: url).markers().map(\.note) == ["Updated"])
    }

    @Test("Saving a deletion preserves unrelated external markers")
    func deletionPreservesExternalMarker() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let document = try await openRecordingTestDocument(url)
      try document.createMarker(note: "Delete", at: .zero)
      try await saveRecordingTestDocument(document, to: url)
      try document.deleteMarker(try #require(document.markers.first))
      _ = try RecordingMarkerStore(recordingDirectoryURL: url).createMarker(
        at: CMTime(seconds: 1, preferredTimescale: 1000), note: "External")
      try await saveRecordingTestDocument(document, to: url)
      #expect(
        try RecordingMarkerStore(recordingDirectoryURL: url).markers().map(\.note) == ["External"])
    }
  }
}
