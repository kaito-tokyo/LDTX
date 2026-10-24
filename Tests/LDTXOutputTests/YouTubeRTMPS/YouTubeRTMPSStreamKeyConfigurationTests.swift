// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import LDTXYouTubeRTMPS
import Testing

extension OutputTestSuite {
  @Suite
  struct YouTubeRTMPSStreamKeyConfigurationUnitTestSuite {
    @Test("LUB-1016: Round trips all endpoints with the shared key")
    func roundTripsAllEndpointsWithTheSharedKey() throws {
      let configuration = YouTubeRTMPSStreamKeyConfiguration(
        name: "Example", streamURL: "rtmps://primary.example/live2",
        backupServerURL: "rtmps://backup.example/live2", streamKey: "test-key")
      let restored = try JSONDecoder().decode(
        YouTubeRTMPSStreamKeyConfiguration.self, from: JSONEncoder().encode(configuration))
      #expect(restored == configuration)
      #expect(try restored.destination().ingestionURL.host == "primary.example")
      #expect(try restored.backupDestination()?.ingestionURL.host == "backup.example")
      #expect(try restored.destination().streamName == restored.backupDestination()?.streamName)
      #expect(String(describing: restored) == "YouTubeRTMPSStreamKeyConfiguration(<redacted>)")
      #expect(String(reflecting: restored) == "YouTubeRTMPSStreamKeyConfiguration(<redacted>)")
    }

    @Test("LUB-1016: Accepts primary without backup") func acceptsPrimaryWithoutBackup() throws {
      let configuration = YouTubeRTMPSStreamKeyConfiguration(
        name: "Example", streamURL: "rtmps://primary.example/live2", streamKey: "test-key")
      #expect(try configuration.backupDestination() == nil)
    }

    @Test(
      "LUB-1016: Rejects invalid backup even when primary is valid",
      arguments: [
        "rtmp://backup.example/live2", "https://backup.example/live2",
        "rtmps://backup.example:1935/live2", "rtmps://backup.example/",
        "rtmps://user:password@backup.example/live2", "rtmps://backup.example/live2?key=secret",
      ])
    func rejectsInvalidBackupEvenWhenPrimaryIsValid(backup: String) {
      let configuration = YouTubeRTMPSStreamKeyConfiguration(
        name: "Example", streamURL: "rtmps://primary.example/live2",
        backupServerURL: backup, streamKey: "test-key")
      #expect(throws: YouTubeRTMPSError.invalidDestination) { try configuration.destination() }
    }

    @Test("LUB-1016: Rejects empty name or key") func rejectsEmptyNameOrKey() {
      for (name, key) in [("", "key"), ("Example", "  ")] {
        let configuration = YouTubeRTMPSStreamKeyConfiguration(
          name: name, streamURL: "rtmps://primary.example/live2", streamKey: key)
        #expect(throws: YouTubeRTMPSError.invalidDestination) { try configuration.destination() }
      }
    }

    @Test("LUB-1016: Rejects same key for both outputs") func rejectsSameKeyForBothOutputs() throws
    {
      let configuration = YouTubeRTMPSStreamKeyConfiguration(
        name: "Example", streamURL: "rtmps://primary.example/live2", streamKey: "test-key")
      #expect(throws: YouTubeRTMPSError.invalidDestination) {
        try YouTubeDualRTMPSDestinations(
          landscape: configuration.destination(), portrait: configuration.destination())
      }
    }
  }
}
