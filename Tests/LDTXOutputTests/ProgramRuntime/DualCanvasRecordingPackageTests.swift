// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import LDTXProgramRuntime
import Testing

extension OutputTestSuite {
  @Suite
  struct DualCanvasRecordingPackageIntegrationTestSuite {
    private struct Metadata: Decodable {
      var formatVersion: Int
      var landscapeMediaFile: String?
      var portraitMediaFile: String?
      var mainMediaFile: String?

      enum CodingKeys: String, CodingKey {
        case formatVersion = "LDTXRecordingFormatVersion"
        case landscapeMediaFile = "LDTXRecordingLandscapeMediaFile"
        case portraitMediaFile = "LDTXRecordingPortraitMediaFile"
        case mainMediaFile = "LDTXRecordingMainMediaFile"
      }
    }

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

      let info = try PropertyListDecoder().decode(
        Metadata.self, from: Data(contentsOf: directory.appendingPathComponent("Info.plist")))
      #expect(info.formatVersion == 3)
      #expect((info.landscapeMediaFile != nil) == enabled.0)
      #expect((info.portraitMediaFile != nil) == enabled.1)
      #expect(info.mainMediaFile == nil)
    }
  }
}
