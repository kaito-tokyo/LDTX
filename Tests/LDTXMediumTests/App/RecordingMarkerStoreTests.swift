// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import Foundation
import LDTXRecordPlayerApplet
import Testing

@Suite
struct RecordingMarkerStoreIntegrationTestSuite {
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

  @Test func rejectsUnreadableMarkerFiles() throws {
    let recordingURL = try makeRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: recordingURL) }
    let markersURL = recordingURL.appendingPathComponent("Markers", isDirectory: true)
    try FileManager.default.createDirectory(at: markersURL, withIntermediateDirectories: false)
    try Data([0xFF]).write(to: markersURL.appendingPathComponent("00-00-01.000.txt"))
    try "Overflow\n".write(
      to: markersURL.appendingPathComponent("9223372036854775807-00-00.000.txt"),
      atomically: true,
      encoding: .utf8
    )
    try "Valid\n".write(
      to: markersURL.appendingPathComponent("00-00-02.000.txt"),
      atomically: true,
      encoding: .utf8
    )

    #expect(throws: (any Error).self) {
      _ = try RecordingMarkerStore(recordingDirectoryURL: recordingURL).markers()
    }
  }

  @Test func snapshotSavePreservesMediaMetadataAndUnknownFiles() throws {
    let url = try makeRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = RecordingMarkerStore(recordingDirectoryURL: url)
    _ = try store.createMarker(at: .zero, note: "Old")
    let baseline = try store.markers()
    let unknown = url.appendingPathComponent("Markers/notes.bin")
    try Data([1, 2, 3]).write(to: unknown)
    for name in ["main.mp4", "Info.plist", "manifest.mpd"] {
      try Data([4, 5, 6]).write(to: url.appendingPathComponent(name))
    }
    let time = CMTime(seconds: 5, preferredTimescale: 1000)
    let marker = RecordingMarker(
      time: time, timecode: "00:00:05.000", note: "New",
      fileURL: url.appendingPathComponent("Markers/00-00-05.000.txt"))
    try store.save([marker], replacing: baseline)
    #expect(try store.markers().map(\.note) == ["New"])
    #expect(try Data(contentsOf: unknown) == Data([1, 2, 3]))
    for name in ["main.mp4", "Info.plist", "manifest.mpd"] {
      #expect(try Data(contentsOf: url.appendingPathComponent(name)) == Data([4, 5, 6]))
    }
    try store.save([], replacing: store.markers())
    #expect(try store.markers().isEmpty)
    #expect(try Data(contentsOf: unknown) == Data([1, 2, 3]))
  }

  @Test func snapshotSaveRejectsExternalChangesAndActiveRecording() throws {
    let url = try makeRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = RecordingMarkerStore(recordingDirectoryURL: url)
    _ = try store.createMarker(at: .zero, note: "Original")
    let baseline = try store.markers()
    try "External\n".write(to: baseline[0].fileURL, atomically: true, encoding: .utf8)
    #expect(throws: RecordingMarkerError.externalChanges) {
      try store.save([], replacing: baseline)
    }
    let current = try store.markers()
    try Data().write(to: url.appendingPathComponent(".shield.json"))
    #expect(throws: RecordingMarkerError.recordingInProgress) {
      try store.save([], replacing: current)
    }
    #expect(try store.markers() == current)
  }

  @Test func snapshotFailureLeavesOriginalAndFirstSaveCreatesDirectory() throws {
    let url = try makeRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = RecordingMarkerStore(recordingDirectoryURL: url)
    let marker = RecordingMarker(
      time: .zero, timecode: "00:00:00.000", note: "First",
      fileURL: url.appendingPathComponent("Markers/00-00-00.000.txt"))
    try store.save([marker], replacing: [])
    let baseline = try store.markers()
    let invalid = RecordingMarker(time: .zero, timecode: "", note: "", fileURL: marker.fileURL)
    #expect(throws: RecordingMarkerError.emptyNote) {
      try store.save([invalid], replacing: baseline)
    }
    #expect(try store.markers() == baseline)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: url.path).allSatisfy {
        !$0.hasPrefix(".markers-save-")
      })
  }

  private func makeRecordingDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("ldtxrecord")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }
}
