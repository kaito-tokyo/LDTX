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

    #expect(
      !FileManager.default.fileExists(
        atPath: recordingURL.appendingPathComponent("Markers").appendingPathComponent(
          marker.fileName
        ).path))
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

  @Test func savePreservesExternalMarkersMediaAndUnknownFiles() throws {
    let url = try makeRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = RecordingMarkerStore(recordingDirectoryURL: url)
    _ = try store.createMarker(at: .zero, note: "External")
    let unknown = url.appendingPathComponent("Markers/notes.bin")
    try Data([1, 2, 3]).write(to: unknown)
    for name in ["main.mp4", "Info.plist", "manifest.mpd"] {
      try Data([4, 5, 6]).write(to: url.appendingPathComponent(name))
    }
    let loaded = try store.save([marker(5, "New")])
    #expect(loaded.map(\.note) == ["External", "New"])
    #expect(try store.save([]) == loaded)
    #expect(try Data(contentsOf: unknown) == Data([1, 2, 3]))
    for name in ["main.mp4", "Info.plist", "manifest.mpd"] {
      #expect(try Data(contentsOf: url.appendingPathComponent(name)) == Data([4, 5, 6]))
    }
  }

  @Test func saveOverwritesWithoutComparingExternalEditsAndRejectsActiveRecording() throws {
    let url = try makeRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = RecordingMarkerStore(recordingDirectoryURL: url)
    _ = try store.createMarker(at: .zero, note: "External")
    #expect(try store.save([marker(0, "Edited")]).map(\.note) == ["Edited"])
    try Data().write(to: url.appendingPathComponent(".shield.json"))
    #expect(throws: RecordingMarkerError.recordingInProgress) {
      try store.save([marker(0, "Blocked")])
    }
    #expect(throws: RecordingMarkerError.recordingInProgress) {
      try store.deleteMarker(marker(0, "Edited"))
    }
    #expect(try store.markers().map(\.note) == ["Edited"])
  }

  @Test func partialSaveCanBeRetriedWithoutLosingExistingFiles() throws {
    let url = try makeRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = RecordingMarkerStore(recordingDirectoryURL: url)
    _ = try store.createMarker(at: .zero, note: "Old")
    let blocked = url.appendingPathComponent("Markers/00-00-02.000.txt")
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) {
      try store.save([marker(1, "Written"), marker(2, "Retry")])
    }
    #expect(try store.markers().map(\.note) == ["Old", "Written"])
    try FileManager.default.removeItem(at: blocked)
    #expect(
      try store.save([marker(1, "Written"), marker(2, "Retry")]).map(\.note)
        == ["Old", "Written", "Retry"])
  }

  @Test func canonicalTimestampUsesFirstExistingNameAndKeepsOtherNames() throws {
    let url = try makeRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    let directory = url.appendingPathComponent("Markers")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let names = ["0-00-01.000.TXT", "000-00-01.000.txt"].sorted()
    for name in names { try Data("Old\n".utf8).write(to: directory.appendingPathComponent(name)) }
    let loaded = try RecordingMarkerStore(recordingDirectoryURL: url).save([marker(1, "New")])
    #expect(loaded.map(\.fileName) == names)
    #expect(loaded.map(\.note) == ["New", "Old"])
    #expect(
      try RecordingMarkerStore(recordingDirectoryURL: url).save(loaded).map(\.note) == [
        "New", "Old",
      ])
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("00-00-01.000.txt").path))
  }

  @Test func emptyLoadedNotesCanBeSavedAndTraversalIsRejected() throws {
    let url = try makeRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = RecordingMarkerStore(recordingDirectoryURL: url)
    try store.save([marker(0, ""), marker(1, "  ")])
    let loaded = try store.markers()
    #expect(try store.save(loaded + [marker(2, "New")]).map(\.note) == ["", "  ", "New"])
    let invalid = RecordingMarker(
      time: .zero, timecode: "", note: "Escape", fileName: "../00-00-00.000.txt")
    #expect(throws: RecordingMarkerError.invalidMarkerFile) { try store.save([invalid]) }
    #expect(
      !FileManager.default.fileExists(atPath: url.appendingPathComponent("00-00-00.000.txt").path))
  }

  @Test func rereadFailureAllowsRetryAndMissingDeletionIsSuccessful() throws {
    let url = try makeRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = RecordingMarkerStore(recordingDirectoryURL: url)
    try store.save([marker(0, "Saved")])
    let invalid = url.appendingPathComponent("Markers/00-00-01.000.txt")
    try Data([0xff]).write(to: invalid)
    #expect(throws: (any Error).self) { try store.save([marker(0, "Committed")]) }
    #expect(
      try String(
        contentsOf: url.appendingPathComponent("Markers/00-00-00.000.txt"), encoding: .utf8)
        == "Committed\n")
    try FileManager.default.removeItem(at: invalid)
    #expect(try store.save([marker(0, "Committed")]).map(\.note) == ["Committed"])
    try store.deleteMarker(marker(0, "Committed"))
    try store.deleteMarker(marker(0, "Committed"))
    #expect(try store.markers().isEmpty)
  }

  @Test func saveDoesNotOverwriteSymbolicLinks() throws {
    let url = try makeRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    let directory = url.appendingPathComponent("Markers")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let target = url.appendingPathComponent("media.txt")
    try Data("Untouched".utf8).write(to: target)
    let link = directory.appendingPathComponent("00-00-00.000.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: RecordingMarkerError.invalidMarkerFile) {
      try RecordingMarkerStore(recordingDirectoryURL: url).save([marker(0, "Edited")])
    }
    #expect(try Data(contentsOf: target) == Data("Untouched".utf8))
    #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
  }

  @Test func saveRoundsPlaybackTimeToMarkerPrecision() throws {
    let url = try makeRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    let time = CMTime(value: 1, timescale: 600)
    let marker = RecordingMarker(
      time: time, timecode: try RecordingMarkerStore.displayTimecode(for: time),
      note: "Frame", fileName: try RecordingMarkerStore.fileName(for: time))
    #expect(
      try RecordingMarkerStore(recordingDirectoryURL: url).save([marker]).first?.fileName
        == "00-00-00.002.txt")
  }

  private func marker(_ seconds: Double, _ note: String) throws -> RecordingMarker {
    let time = CMTime(seconds: seconds, preferredTimescale: 1000)
    return RecordingMarker(
      time: time, timecode: try RecordingMarkerStore.displayTimecode(for: time),
      note: note, fileName: try RecordingMarkerStore.fileName(for: time))
  }

  private func makeRecordingDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("ldtxrecord")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }
}
