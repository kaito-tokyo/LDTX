// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import LDTXCorelibs
import Testing

@Suite
struct RecordingPackageIntegrationTestSuite {
  private struct Metadata: Codable {
    var bundleIdentifier: String
    var infoDictionaryVersion: String
    var bundleName: String
    var packageType: String
    var formatVersion: Int
    var identifier: String
    var manifestFile: String
    var mainMediaFile: String?
    var landscapeMediaFile: String?
    var portraitMediaFile: String?
    var audioTracks: [[String: String]]

    enum CodingKeys: String, CodingKey {
      case bundleIdentifier = "CFBundleIdentifier"
      case infoDictionaryVersion = "CFBundleInfoDictionaryVersion"
      case bundleName = "CFBundleName"
      case packageType = "CFBundlePackageType"
      case formatVersion = "LDTXRecordingFormatVersion"
      case identifier = "LDTXRecordingIdentifier"
      case manifestFile = "LDTXRecordingManifestFile"
      case mainMediaFile = "LDTXRecordingMainMediaFile"
      case landscapeMediaFile = "LDTXRecordingLandscapeMediaFile"
      case portraitMediaFile = "LDTXRecordingPortraitMediaFile"
      case audioTracks = "LDTXRecordingAudioTracks"
    }
  }

  private func encodeMetadata(_ metadata: Metadata) throws -> Data {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .xml
    return try encoder.encode(metadata)
  }

  @Test(
    "LUB-1003: Reads packages with legacy and current bundle identifiers",
    arguments: ["tokyo.kaito.ldtx.recording", "tokyo.kaito.ldtx.record"])
  func readsPackagesWithLegacyAndCurrentBundleIdentifiers(_ bundleIdentifier: String) throws {
    let url = try makePackage()
    defer { try? FileManager.default.removeItem(at: url) }
    let infoURL = url.appendingPathComponent(RecordingPackageInfo.fileName)
    var info = try PropertyListDecoder().decode(Metadata.self, from: Data(contentsOf: infoURL))
    info.bundleIdentifier = bundleIdentifier
    try encodeMetadata(info).write(to: infoURL)
    #expect(try RecordingPackage(contentsOf: url).formatVersion == 2)
  }

  @Test("LUB-1003: Loads info and resolves media files") func loadsInfoAndResolvesMediaFiles()
    throws
  {
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

  @Test("LUB-1003: Version three loads independent canvas media without main media key")
  func versionThreeLoadsIndependentCanvasMediaWithoutMainMediaKey() throws {
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
    let values = try PropertyListDecoder().decode(Metadata.self, from: info)
    #expect(values.mainMediaFile == nil)
    try info.write(to: packageURL.appendingPathComponent(RecordingPackageInfo.fileName))

    let package = try RecordingPackage(contentsOf: packageURL)
    #expect(package.formatVersion == 3)
    #expect(package.availableCanvases == [.landscape, .portrait])
    #expect(package.media(for: .landscape)?.path == "landscape.fragmented.mp4")
    #expect(package.media(for: .portrait)?.path == "portrait.fragmented.mp4")
    #expect(package.audioTracks.map(\.identifier) == ["landscape-mix", "portrait-mix"])
  }

  @Test("LUB-1003: Version three ignores legacy main media key")
  func versionThreeIgnoresLegacyMainMediaKey() throws {
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
    var values = try PropertyListDecoder().decode(
      Metadata.self,
      from: RecordingPackageInfo.v3Data(
        identifier: "portrait-only",
        landscapeMediaFile: nil,
        portraitMediaFile: portraitName))
    values.mainMediaFile = "legacy.mp4"
    let info = try encodeMetadata(values)
    try info.write(to: packageURL.appendingPathComponent(RecordingPackageInfo.fileName))

    let package = try RecordingPackage(contentsOf: packageURL)
    #expect(package.mainMediaURL.lastPathComponent == portraitName)
  }

  @Test("LUB-1003: Version three loads when an unselected canvas file is missing")
  func versionThreeLoadsWhenAnUnselectedCanvasFileIsMissing() throws {
    let packageURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(RecordingPackage.pathExtension)
    defer { try? FileManager.default.removeItem(at: packageURL) }
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    let landscapeName = "landscape.fragmented.mp4"
    FileManager.default.createFile(
      atPath: packageURL.appendingPathComponent(landscapeName).path,
      contents: Data([0]))
    let info = try RecordingPackageInfo.v3Data(
      identifier: "incomplete-dual",
      landscapeMediaFile: landscapeName,
      portraitMediaFile: "portrait.fragmented.mp4")
    try info.write(to: packageURL.appendingPathComponent(RecordingPackageInfo.fileName))

    let package = try RecordingPackage(contentsOf: packageURL)
    #expect(package.media(for: .landscape)?.path == landscapeName)
    #expect(package.media(for: .portrait)?.path == "portrait.fragmented.mp4")
    #expect(package.mainMediaPath == landscapeName)
  }

  @Test("LUB-1003: Version three prefers existing portrait for main media alias")
  func versionThreePrefersExistingPortraitForMainMediaAlias() throws {
    let packageURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(RecordingPackage.pathExtension)
    defer { try? FileManager.default.removeItem(at: packageURL) }
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    let portraitName = "portrait.fragmented.mp4"
    FileManager.default.createFile(
      atPath: packageURL.appendingPathComponent(portraitName).path,
      contents: Data([0]))
    let info = try RecordingPackageInfo.v3Data(
      identifier: "portrait-recovery",
      landscapeMediaFile: "landscape.fragmented.mp4",
      portraitMediaFile: portraitName)
    try info.write(to: packageURL.appendingPathComponent(RecordingPackageInfo.fileName))

    let package = try RecordingPackage(contentsOf: packageURL)
    #expect(package.mainMediaPath == portraitName)
    #expect(package.mainMediaURL.lastPathComponent == portraitName)
  }

  @Test("LUB-1003: Exposes embedded main mix as an audio track")
  func exposesEmbeddedMainMixAsAnAudioTrack() throws {
    let packageURL = try makePackage()
    defer { try? FileManager.default.removeItem(at: packageURL) }

    let package = try RecordingPackage(contentsOf: packageURL)

    #expect(package.formatVersion == 2)
    #expect(package.audioTracks.map(\.identifier) == ["main-mix", "main", "microphone"])
    #expect(package.audioTracks.first?.mediaURL == package.mainMediaURL)
  }

  @Test("LUB-1003: Rejects unsupported format versions for writing and reading")
  func rejectsUnsupportedFormatVersionsForWritingAndReading() throws {
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
    var values = try PropertyListDecoder().decode(Metadata.self, from: data)
    values.formatVersion = 1
    try encodeMetadata(values).write(to: infoURL)

    #expect(throws: RecordingPackageError.unsupportedFormatVersion(1)) {
      try RecordingPackage(contentsOf: packageURL)
    }
  }

  @Test("LUB-1003: Version two rejects an input track using the reserved main mix identifier")
  func versionTwoRejectsAnInputTrackUsingTheReservedMainMixIdentifier() throws {
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

  @Test("LUB-1003: Loads package before fixed manifest exists")
  func loadsPackageBeforeFixedManifestExists() throws {
    let packageURL = try makePackage()
    defer { try? FileManager.default.removeItem(at: packageURL) }
    try FileManager.default.removeItem(
      at: packageURL.appendingPathComponent(RecordingPackage.manifestFileName)
    )

    let package = try RecordingPackage(contentsOf: packageURL)
    #expect(package.manifestPath == RecordingPackage.manifestFileName)
    #expect(package.manifestURL == nil)
  }

  @Test("LUB-1003: Recognizes finalized marker and requires it by default")
  func recognizesFinalizedMarkerAndRequiresItByDefault() throws {
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

  @Test("LUB-1003: Rejects media path outside package") func rejectsMediaPathOutsidePackage() throws
  {
    let packageURL = try makePackage(mainMediaFile: "../outside.mp4")
    defer { try? FileManager.default.removeItem(at: packageURL) }

    #expect(throws: RecordingPackageError.invalidRelativePath("../outside.mp4")) {
      try RecordingPackage(contentsOf: packageURL)
    }
  }

  @Test("LUB-1003: Rejects referenced symbolic link") func rejectsReferencedSymbolicLink() throws {
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

  @Test("LUB-1003: Rejects unreferenced nested symbolic link")
  func rejectsUnreferencedNestedSymbolicLink() throws {
    let packageURL = try makePackage()
    defer { try? FileManager.default.removeItem(at: packageURL) }
    let nestedDirectory = packageURL.appendingPathComponent("Unused", isDirectory: true)
    try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: nestedDirectory.appendingPathComponent("external"),
      withDestinationURL: FileManager.default.temporaryDirectory
    )

    do {
      _ = try RecordingPackage(contentsOf: packageURL)
      Issue.record("Expected symbolic link rejection")
    } catch RecordingPackageError.symbolicLinkNotAllowed(let path) {
      #expect(path == "external" || path == "Unused/external")
    }

  }

  @Test("LUB-1003: Rejects symbolic link package root") func rejectsSymbolicLinkPackageRoot() throws
  {
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

  @Test(
    "LUB-1003: Reads relative track starts from DASH manifest",
    arguments: [String?.none, "18500", "invalid", "9223372036854775808"])
  func readsRelativeTrackStartsFromDASHManifest(audioStart: String?) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manifestURL = directory.appendingPathComponent("manifest.mpd")
    let property =
      audioStart.map {
        "<SupplementalProperty schemeIdUri=\"\(RecordingDASHManifestTimeline.audioStartScheme)\" value=\"\($0)\"/>"
      } ?? ""
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <MPD xmlns="urn:mpeg:dash:schema:mpd:2011">
      <Period start="PT0S">
        <AdaptationSet><Representation>\(property)<SegmentList timescale="1000000" presentationTimeOffset="100000000">
          <Initialization sourceURL="output-video.mp4"/><SegmentTimeline><S t="100000000" d="1000000"/></SegmentTimeline>
        </SegmentList></Representation></AdaptationSet>
        <AdaptationSet><Representation><SegmentList timescale="1000000" presentationTimeOffset="100000000">
          <Initialization sourceURL="InputDevices/Desk%2520Mic.mp4"/><SegmentTimeline><S t="100200000" d="1000000"/></SegmentTimeline>
        </SegmentList></Representation></AdaptationSet>
      </Period>
    </MPD>
    """.write(to: manifestURL, atomically: true, encoding: .utf8)

    if let audioStart, Int64(audioStart) == nil {
      #expect(throws: (any Error).self) {
        try RecordingDASHManifestTimeline(contentsOf: manifestURL)
      }
      return
    }
    let timeline = try RecordingDASHManifestTimeline(contentsOf: manifestURL)
    #expect(timeline.presentationStart(for: "output-video.mp4") == 0)
    #expect(timeline.presentationStart(for: "InputDevices/Desk%20Mic.mp4") == 200_000_000)
    #expect(
      timeline.audioPresentationStart(for: "output-video.mp4")
        == audioStart.flatMap(Int64.init))
    #expect(timeline.audioPresentationStart(for: "InputDevices/Desk%20Mic.mp4") == nil)
  }

  @Test(
    "LUB-1003: Rejects non portable paths",
    arguments: [
      "C:/outside.mp4", "C:\\outside.mp4", "\\\\server\\share.mp4", "..\\outside.mp4",
      "/outside.mp4",
    ])
  func rejectsNonPortablePaths(_ path: String) throws {
    let url = try makePackage(mainMediaFile: path)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: RecordingPackageError.invalidRelativePath(path)) {
      try RecordingPackage(contentsOf: url)
    }
  }

  @Test("LUB-1003: Custom fields round trip and preserve other files")
  func customFieldsRoundTripAndPreserveOtherFiles() throws {
    let url = try makePackage()
    defer { try? FileManager.default.removeItem(at: url) }
    let infoURL = url.appendingPathComponent(RecordingPackageInfo.fileName)
    let original = try Data(contentsOf: infoURL)
    let fields = ["title": "録画", "note": "first\nsecond"]
    try RecordingCustomFieldsFile.write(fields, to: url)
    let saved = try Data(
      contentsOf: url.appendingPathComponent(RecordingPackage.customFieldsFileName))
    #expect(try JSONDecoder().decode([String: String].self, from: saved) == fields)
    #expect(try Data(contentsOf: infoURL) == original)
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
