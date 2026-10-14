// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation
import LDTXRecordBundleFormat
@testable import LDTXRecordPlayerApplet
import LDTXRecording
import Testing
import UniformTypeIdentifiers

extension AppUIComponentTestSuite {
  @Suite("UCT-1021: URL Document reading", .serialized)
  @MainActor
  struct UCT1021RecordPlayerDocumentIntegrationTestSuite {
    @Test("Malformed optional markers allow viewing but block writing")
    func malformedMarkers() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let markerURL = try RecordingMarkerStore(recordingDirectoryURL: url).createMarker(
        at: .zero, note: "Original")
      let malformed = Data([0xff, 0xfe])
      try malformed.write(to: markerURL)
      let document = try await openRecordingTestDocument(url)
      #expect(document.markers.isEmpty)
      try document.createMarker(note: "Pending", at: CMTime(seconds: 1, preferredTimescale: 1000))
      await #expect(throws: (any Error).self) {
        try await saveRecordingTestDocument(document, to: url)
      }
      #expect(try Data(contentsOf: markerURL) == malformed)
      #expect(document.markers.map(\.note) == ["Pending"])
      await #expect(throws: (any Error).self) {
        try await document.apply(snapshot: readRecordingTestSnapshot(url), previous: nil)
      }
      #expect(document.markers.map(\.note) == ["Pending"])
    }

    @Test("Missing recording metadata is rejected by the reader")
    func invalidPackage() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      try FileManager.default.removeItem(
        at: url.appendingPathComponent(RecordingPackageInfo.fileName))
      await #expect(throws: (any Error).self) { try await readRecordingTestSnapshot(url) }
    }

    @Test("Both existing recording type identifiers remain supported")
    func recordingTypes() {
      #expect(
        RecordPlayerDocument.readableContentTypes.contains(
          UTType(importedAs: RecordingPackageInfo.typeIdentifier, conformingTo: .package)))
      #expect(
        RecordPlayerDocument.readableContentTypes.contains(
          UTType(importedAs: RecordingPackageInfo.legacyTypeIdentifier, conformingTo: .package)))
    }

    @Test("Reader snapshot updates the URL used by playback after a recording moves")
    func movedRecording() async throws {
      let url = try makeRecordingTestPackage()
      let moved = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("ldtxrecord")
      defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: moved)
      }
      let document = try await openRecordingTestDocument(url)
      try FileManager.default.moveItem(at: url, to: moved)
      try await document.apply(snapshot: readRecordingTestSnapshot(moved), previous: nil)
      var loadedURL: URL?
      document.assetLoader = { url, _ in
        loadedURL = url
        return AVMutableComposition()
      }
      document.model.start()
      for _ in 0..<100 where loadedURL == nil { try await Task.sleep(for: .milliseconds(10)) }
      #expect(document.fileURL == moved)
      #expect(loadedURL == moved)
    }
  }
}
