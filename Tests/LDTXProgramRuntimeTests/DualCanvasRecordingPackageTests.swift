// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import LDTXProgramRuntime

struct DualCanvasRecordingPackageTests {
  @Test(arguments: [(true, false), (false, true), (true, true)])
  func versionThreeCreatesOnlyEnabledCanvasFiles(_ enabled: (Bool, Bool)) throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXDualRecording-\(UUID().uuidString).ldtxrecord",
      isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    _ = try HLSByteRangeRecordingPackage(
      configuration: HLSByteRangeRecordingPackageConfiguration(
        directory: directory,
        recordID: "dual-canvas-test",
        targetDurationSeconds: 2,
        videoCodecs: "avc1.64002a",
        audioCodecs: "mp4a.40.2",
        bandwidth: 1_000_000,
        includesMainAudioTrack: true,
        audioTracks: [],
        formatVersion: 3,
        recordsLandscape: enabled.0,
        recordsPortrait: enabled.1))

    let landscapeURL = directory.appendingPathComponent("landscape.fragmented.mp4")
    let portraitURL = directory.appendingPathComponent("portrait.fragmented.mp4")
    #expect(FileManager.default.fileExists(atPath: landscapeURL.path) == enabled.0)
    #expect(FileManager.default.fileExists(atPath: portraitURL.path) == enabled.1)
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("main.fragmented.mp4").path))

    let info = try #require(
      PropertyListSerialization.propertyList(
        from: Data(contentsOf: directory.appendingPathComponent("Info.plist")),
        options: 0,
        format: nil) as? [String: Any])
    #expect(info["LDTXRecordingFormatVersion"] as? Int == 3)
    #expect(((info["LDTXRecordingLandscapeMediaFile"] as? String) != nil) == enabled.0)
    #expect(((info["LDTXRecordingPortraitMediaFile"] as? String) != nil) == enabled.1)
    #expect(info["LDTXRecordingMainMediaFile"] == nil)
  }
}
