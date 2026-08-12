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

    #expect(package.formatVersion == 2)
    #expect(package.identifier == "recording-test")
    #expect(!package.isFinalized)
    #expect(package.mainMediaURL.lastPathComponent == "main-stream.mp4")
    #expect(package.manifestPath == RecordingPackage.manifestFileName)
    #expect(package.manifestURL?.lastPathComponent == "manifest.mpd")
    #expect(package.masterPlaylistURL == nil)
    #expect(package.audioTracks.map(\.identifier) == ["main-mix", "main", "microphone"])
    #expect(
      package.audioTracks.map(\.mediaURL.lastPathComponent) == [
        "main-stream.mp4", "main-audio.mp4", "side-track.mp4",
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
    #expect(values["LDTXRecordingFormatVersion"] as? Int == 2)
  }

  @Test func versionThreeLoadsIndependentCanvasMediaWithoutMainMediaKey() throws {
    let packageURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(RecordingPackage.pathExtension)
    defer { try? FileManager.default.removeItem(at: packageURL) }
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    for name in ["landscape.fragmented.mp4", "portrait.fragmented.mp4"] {
      FileManager.default.createFile(
        atPath: packageURL.appendingPathComponent(name).path,
        contents: Data()
      )
    }
    let info = try RecordingPackageInfo.v3Data(
      identifier: "dual",
      landscapeMediaFile: "landscape.fragmented.mp4",
      portraitMediaFile: "portrait.fragmented.mp4"
    )
    let values = try #require(
      PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any]
    )
    #expect(values[RecordingPackageInfo.mainMediaFileKey] == nil)
    try info.write(to: packageURL.appendingPathComponent(RecordingPackageInfo.fileName))

    let package = try RecordingPackage(contentsOf: packageURL)
    #expect(package.formatVersion == 3)
    #expect(package.availableCanvases == [.landscape, .portrait])
    #expect(package.media(for: .landscape)?.path == "landscape.fragmented.mp4")
    #expect(package.media(for: .portrait)?.path == "portrait.fragmented.mp4")
    #expect(package.audioTracks.map(\.identifier) == ["landscape-mix", "portrait-mix"])
  }

  @Test func versionThreeIgnoresLegacyMainMediaKey() throws {
    let packageURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(RecordingPackage.pathExtension)
    defer { try? FileManager.default.removeItem(at: packageURL) }
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    let portraitName = "portrait.fragmented.mp4"
    FileManager.default.createFile(
      atPath: packageURL.appendingPathComponent(portraitName).path,
      contents: Data([0])
    )
    var values = try #require(
      PropertyListSerialization.propertyList(
        from: RecordingPackageInfo.v3Data(
          identifier: "portrait-only",
          landscapeMediaFile: nil,
          portraitMediaFile: portraitName),
        format: nil) as? [String: Any]
    )
    values[RecordingPackageInfo.mainMediaFileKey] = "legacy.mp4"
    let info = try PropertyListSerialization.data(
      fromPropertyList: values, format: .xml, options: 0)
    try info.write(to: packageURL.appendingPathComponent(RecordingPackageInfo.fileName))

    let package = try RecordingPackage(contentsOf: packageURL)
    #expect(package.mainMediaURL.lastPathComponent == portraitName)
  }

  @Test func exposesEmbeddedMainMixAsAnAudioTrack() throws {
    let packageURL = try makePackage()
    defer { try? FileManager.default.removeItem(at: packageURL) }

    let package = try RecordingPackage(contentsOf: packageURL)

    #expect(package.formatVersion == 2)
    #expect(package.audioTracks.map(\.identifier) == ["main-mix", "main", "microphone"])
    #expect(package.audioTracks.first?.mediaURL == package.mainMediaURL)
  }

  @Test func rejectsUnsupportedFormatVersionsForWritingAndReading() throws {
    #expect(throws: RecordingPackageInfoError.unsupportedFormatVersion(1)) {
      try RecordingPackageInfo.data(
        identifier: "recording-test",
        mainMediaFile: "main.fragmented.mp4",
        audioTracks: [],
        formatVersion: 1
      )
    }
    #expect(throws: RecordingPackageInfoError.unsupportedFormatVersion(3)) {
      try RecordingPackageInfo.data(
        identifier: "recording-test",
        mainMediaFile: "main.fragmented.mp4",
        audioTracks: [],
        formatVersion: 3
      )
    }

    let packageURL = try makePackage()
    defer { try? FileManager.default.removeItem(at: packageURL) }
    let infoURL = packageURL.appendingPathComponent(RecordingPackageInfo.fileName)
    let data = try Data(contentsOf: infoURL)
    var values = try #require(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    )
    values[RecordingPackageInfo.formatVersionKey] = 1
    try PropertyListSerialization.data(
      fromPropertyList: values,
      format: .xml,
      options: 0
    ).write(to: infoURL)

    #expect(throws: RecordingPackageError.unsupportedFormatVersion(1)) {
      try RecordingPackage(contentsOf: packageURL)
    }
  }

  @Test func versionTwoRejectsAnInputTrackUsingTheReservedMainMixIdentifier() throws {
    let packageURL = try makePackage(formatVersion: 2)
    defer { try? FileManager.default.removeItem(at: packageURL) }
    let infoURL = packageURL.appendingPathComponent(RecordingPackageInfo.fileName)
    let info = try RecordingPackageInfo.data(
      identifier: "recording-test",
      mainMediaFile: "main-stream.mp4",
      audioTracks: [
        RecordingPackageInfoAudioTrack(
          identifier: "main-mix",
          name: "Conflicting Input",
          mediaFile: "side-track.mp4"
        )
      ],
      formatVersion: 2
    )
    try info.write(to: infoURL)

    #expect(throws: RecordingPackageError.duplicateAudioTrackIdentifier("main-mix")) {
      try RecordingPackage(contentsOf: packageURL)
    }
  }

  @Test func remuxReadmeDescribesThePackageWithoutBundledCLI() {
    #expect(RecordingPackage.readmeFileName == "README.md")
    #expect(RecordingPackage.remuxReadme.contains("compatible external media tool"))
    #expect(!RecordingPackage.remuxReadme.contains("Contents/Library/Helpers"))
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

  private func makePackage(
    mainMediaFile: String = "main-stream.mp4",
    formatVersion: Int = 2
  ) throws -> URL {
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
      ],
      formatVersion: formatVersion
    )
    try info.write(to: packageURL.appendingPathComponent(RecordingPackageInfo.fileName))
    return packageURL
  }
}
