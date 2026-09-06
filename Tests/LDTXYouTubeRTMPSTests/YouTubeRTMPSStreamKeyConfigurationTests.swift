// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import LDTXYouTubeRTMPS

struct YouTubeRTMPSStreamKeyConfigurationTests {
  @Test func roundTripsAllEndpointsWithTheSharedKey() throws {
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

  @Test func acceptsPrimaryWithoutBackup() throws {
    let configuration = YouTubeRTMPSStreamKeyConfiguration(
      name: "Example", streamURL: "rtmps://primary.example/live2", streamKey: "test-key")
    #expect(try configuration.backupDestination() == nil)
  }

  @Test(arguments: [
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

  @Test func rejectsEmptyNameOrKey() {
    for (name, key) in [("", "key"), ("Example", "  ")] {
      let configuration = YouTubeRTMPSStreamKeyConfiguration(
        name: name, streamURL: "rtmps://primary.example/live2", streamKey: key)
      #expect(throws: YouTubeRTMPSError.invalidDestination) { try configuration.destination() }
    }
  }

  @Test func rejectsSameKeyForBothOutputs() throws {
    let configuration = YouTubeRTMPSStreamKeyConfiguration(
      name: "Example", streamURL: "rtmps://primary.example/live2", streamKey: "test-key")
    #expect(throws: YouTubeRTMPSError.invalidDestination) {
      try YouTubeDualRTMPSDestinations(
        landscape: configuration.destination(), portrait: configuration.destination())
    }
  }
}
