// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import LDTXRecordPlayerUI

struct RecordingMarkerStoreTests {
  @Test func writesHumanReadableMarkerNote() throws {
    let recordingURL = try makeRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: recordingURL) }
    let store = RecordingMarkerStore(recordingDirectoryURL: recordingURL)

    let markerURL = try store.createMarker(
      at: CMTime(value: 3_723_456, timescale: 1_000),
      note: "Switch to the close-up"
    )

    #expect(markerURL.lastPathComponent == "01-02-03.456.txt")
    #expect(try String(contentsOf: markerURL, encoding: .utf8) == "Switch to the close-up\n")
    #expect(
      try RecordingMarkerStore.displayTimecode(
        for: CMTime(value: 3_723_456, timescale: 1_000)
      ) == "01:02:03.456"
    )
  }

  @Test func rejectsDuplicateMarkerAtSameTime() throws {
    let recordingURL = try makeRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: recordingURL) }
    let store = RecordingMarkerStore(recordingDirectoryURL: recordingURL)
    let time = CMTime(seconds: 12.5, preferredTimescale: 1_000)

    _ = try store.createMarker(at: time, note: "First")
    #expect(throws: RecordingMarkerError.markerAlreadyExists("00-00-12.500.txt")) {
      try store.createMarker(at: time, note: "Second")
    }
  }

  @Test func listsMarkersInPlaybackOrder() throws {
    let recordingURL = try makeRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: recordingURL) }
    let store = RecordingMarkerStore(recordingDirectoryURL: recordingURL)

    _ = try store.createMarker(
      at: CMTime(seconds: 12.5, preferredTimescale: 1_000),
      note: "Later"
    )
    _ = try store.createMarker(
      at: CMTime(seconds: 3.25, preferredTimescale: 1_000),
      note: "Earlier"
    )

    let markers = try store.markers()

    #expect(markers.map(\.timecode) == ["00:00:03.250", "00:00:12.500"])
    #expect(markers.map(\.note) == ["Earlier", "Later"])
  }

  @Test func rejectsInvalidMarkerValues() throws {
    let recordingURL = try makeRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: recordingURL) }
    let store = RecordingMarkerStore(recordingDirectoryURL: recordingURL)

    #expect(throws: RecordingMarkerError.invalidTime) {
      try store.createMarker(at: .invalid, note: "Note")
    }
    #expect(throws: RecordingMarkerError.emptyNote) {
      try store.createMarker(at: .zero, note: "  \n")
    }
  }

  @Test func deletesMarkerFile() throws {
    let recordingURL = try makeRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: recordingURL) }
    let store = RecordingMarkerStore(recordingDirectoryURL: recordingURL)
    _ = try store.createMarker(at: .zero, note: "Delete me")
    let marker = try #require(store.markers().first)

    try store.deleteMarker(marker)

    #expect(!FileManager.default.fileExists(atPath: marker.fileURL.path))
    #expect(try store.markers().isEmpty)
  }

  private func makeRecordingDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("ldtxrecord")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }
}
