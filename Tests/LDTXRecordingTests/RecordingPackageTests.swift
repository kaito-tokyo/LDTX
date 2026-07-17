// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import LDTXRecording

struct RecordingPackageTests {
  @Test func loadsInfoAndResolvesMediaFiles() throws {
    let packageURL = try makePackage()
    defer { try? FileManager.default.removeItem(at: packageURL) }

    let package = try RecordingPackage(contentsOf: packageURL)

    #expect(package.formatVersion == 1)
    #expect(package.identifier == "recording-test")
    #expect(!package.isFinalized)
    #expect(package.mainMediaURL.lastPathComponent == "main-stream.mp4")
    #expect(package.manifestPath == RecordingPackage.manifestFileName)
    #expect(package.manifestURL?.lastPathComponent == "manifest.mpd")
    #expect(package.masterPlaylistURL == nil)
    #expect(package.audioTracks.map(\.identifier) == ["main", "microphone"])
    #expect(
      package.audioTracks.map(\.mediaURL.lastPathComponent) == [
        "main-audio.mp4", "side-track.mp4",
      ])
  }

  @Test func infoAdvertisesFixedManifestPath() throws {
    let data = try RecordingPackageInfo.data(
      identifier: "recording-test",
      mainMediaFile: "output-video.mp4",
      audioTracks: []
    )
    let values = try #require(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    )
    #expect(
      values["LDTXRecordingManifestFile"] as? String == RecordingPackage.manifestFileName
    )
  }

  @Test func loadsPackageBeforeFixedManifestExists() throws {
    let packageURL = try makePackage()
    defer { try? FileManager.default.removeItem(at: packageURL) }
    try FileManager.default.removeItem(
      at: packageURL.appendingPathComponent(RecordingPackage.manifestFileName)
    )

    let package = try RecordingPackage(contentsOf: packageURL)
    #expect(package.manifestPath == RecordingPackage.manifestFileName)
    #expect(package.manifestURL == nil)
  }

  @Test func recognizesFinalizedMarkerAndRequiresItByDefault() throws {
    let packageURL = try makePackage()
    defer { try? FileManager.default.removeItem(at: packageURL) }

    let incomplete = try RecordingPackage(contentsOf: packageURL)
    #expect(throws: RecordingPackageError.packageIsNotFinalized(packageURL.standardizedFileURL)) {
      try incomplete.requireFinalized()
    }
    FileManager.default.createFile(
      atPath: packageURL.appendingPathComponent(RecordingPackage.finalizedMarkerFileName).path,
      contents: Data()
    )
    let finalized = try RecordingPackage(contentsOf: packageURL)
    #expect(finalized.isFinalized)
    try finalized.requireFinalized()
  }

  @Test func verifierRejectsZeroByteMedia() async throws {
    let packageURL = try makePackage()
    defer { try? FileManager.default.removeItem(at: packageURL) }
    let package = try RecordingPackage(contentsOf: packageURL)

    await #expect(
      throws: RecordingPackageVerificationError.invalidMediaFile("main-stream.mp4")
    ) {
      try await RecordingPackageVerifier().verify(package)
    }
  }

  @Test func rejectsMediaPathOutsidePackage() throws {
    let packageURL = try makePackage(mainMediaFile: "../outside.mp4")
    defer { try? FileManager.default.removeItem(at: packageURL) }

    #expect(throws: RecordingPackageError.invalidRelativePath("../outside.mp4")) {
      try RecordingPackage(contentsOf: packageURL)
    }
  }

  @Test func rejectsReferencedSymbolicLink() throws {
    let packageURL = try makePackage()
    defer { try? FileManager.default.removeItem(at: packageURL) }
    let mediaURL = packageURL.appendingPathComponent("side-track.mp4")
    try FileManager.default.removeItem(at: mediaURL)
    try FileManager.default.createSymbolicLink(
      at: mediaURL,
      withDestinationURL: packageURL.appendingPathComponent("main-audio.mp4")
    )

    #expect(throws: RecordingPackageError.symbolicLinkNotAllowed("side-track.mp4")) {
      try RecordingPackage(contentsOf: packageURL)
    }
  }

  @Test func rejectsUnreferencedNestedSymbolicLink() throws {
    let packageURL = try makePackage()
    defer { try? FileManager.default.removeItem(at: packageURL) }
    let nestedDirectory = packageURL.appendingPathComponent("Unused", isDirectory: true)
    try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: nestedDirectory.appendingPathComponent("external"),
      withDestinationURL: FileManager.default.temporaryDirectory
    )

    #expect(throws: RecordingPackageError.symbolicLinkNotAllowed("external")) {
      try RecordingPackage(contentsOf: packageURL)
    }
  }

  @Test func rejectsSymbolicLinkPackageRoot() throws {
    let packageURL = try makePackage()
    defer { try? FileManager.default.removeItem(at: packageURL) }
    let linkURL = packageURL.deletingLastPathComponent()
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(RecordingPackage.pathExtension)
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: packageURL)
    defer { try? FileManager.default.removeItem(at: linkURL) }

    #expect(
      throws: RecordingPackageError.symbolicLinkNotAllowed(linkURL.lastPathComponent)
    ) {
      try RecordingPackage(contentsOf: linkURL)
    }
  }

  @Test func derivesSiblingMP4OutputURL() {
    let packageURL = URL(fileURLWithPath: "/tmp/Example.ldtxrecord")
    #expect(
      RecordingPackage.defaultRemuxOutputURL(for: packageURL).path == "/tmp/Example.mp4"
    )
  }

  @Test func readsRelativeTrackStartsFromDASHManifest() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manifestURL = directory.appendingPathComponent("manifest.mpd")
    try """
      <?xml version="1.0" encoding="UTF-8"?>
      <MPD xmlns="urn:mpeg:dash:schema:mpd:2011">
        <Period start="PT0S">
          <AdaptationSet><Representation><SegmentList timescale="1000000" presentationTimeOffset="100000000">
            <Initialization sourceURL="output-video.mp4"/><SegmentTimeline><S t="100000000" d="1000000"/></SegmentTimeline>
          </SegmentList></Representation></AdaptationSet>
          <AdaptationSet><Representation><SegmentList timescale="1000000" presentationTimeOffset="100000000">
            <Initialization sourceURL="InputDevices/Desk%2520Mic.mp4"/><SegmentTimeline><S t="100200000" d="1000000"/></SegmentTimeline>
          </SegmentList></Representation></AdaptationSet>
        </Period>
      </MPD>
      """.write(to: manifestURL, atomically: true, encoding: .utf8)

    let timeline = try RecordingDASHTimeline(contentsOf: manifestURL)
    #expect(timeline.presentationStart(for: "output-video.mp4")?.seconds == 0)
    #expect(timeline.presentationStart(for: "InputDevices/Desk%20Mic.mp4")?.seconds == 0.2)
  }

  private func makePackage(mainMediaFile: String = "main-stream.mp4") throws -> URL {
    let packageURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(RecordingPackage.pathExtension)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    for name in [
      "main-stream.mp4", "main-audio.mp4", "side-track.mp4", "manifest.mpd",
    ] {
      FileManager.default.createFile(
        atPath: packageURL.appendingPathComponent(name).path,
        contents: Data()
      )
    }
    let info = try RecordingPackageInfo.data(
      identifier: "recording-test",
      mainMediaFile: mainMediaFile,
      audioTracks: [
        RecordingPackageInfoAudioTrack(
          identifier: "main",
          name: "Main Mix",
          mediaFile: "main-audio.mp4"
        ),
        RecordingPackageInfoAudioTrack(
          identifier: "microphone",
          name: "Microphone",
          mediaFile: "side-track.mp4"
        ),
      ]
    )
    try info.write(to: packageURL.appendingPathComponent(RecordingPackageInfo.fileName))
    return packageURL
  }
}
