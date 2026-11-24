// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXCorelibs
import LDTXYouTube
import Testing

@Suite("YouTube stream key configuration import", .tags(.easy))
struct YouTubeStreamKeyConfigurationImportUnitTestSuite {
  private static func stream(
    id: String? = "stream-id", title: String = "Main", ingestionType: String = "rtmp",
    address: String? = "rtmps://a.rtmps.youtube.com/live2",
    backup: String? = "rtmps://b.rtmps.youtube.com/live2?backup=1", key: String? = "abcd-1234"
  ) -> YouTubeLiveStream {
    YouTubeLiveStream(
      id: id, snippet: .init(title: title),
      cdn: .init(
        ingestionType: ingestionType,
        ingestionInfo: .init(
          streamName: key, rtmpsIngestionAddress: address, rtmpsBackupIngestionAddress: backup),
        resolution: "variable", frameRate: "variable"))
  }

  @Test("Converts an RTMPS LiveStream and remembers its source")
  func convertsRTMPSLiveStream() throws {
    let configuration = try YouTubeLiveAPIClient.rtmpsStreamKeyConfiguration(
      from: Self.stream(backup: "rtmps://b.rtmps.youtube.com/live2"))
    #expect(configuration.sourceLiveStreamID == "stream-id")
    #expect(configuration.name == "Main")
    #expect(configuration.streamURL == "rtmps://a.rtmps.youtube.com/live2")
    #expect(configuration.backupServerURL == "rtmps://b.rtmps.youtube.com/live2")
    #expect(configuration.streamKey == "abcd-1234")
  }

  @Test("Drops an unusable backup server and names untitled streams by ID")
  func dropsUnusableBackupServer() throws {
    let configuration = try YouTubeLiveAPIClient.rtmpsStreamKeyConfiguration(
      from: Self.stream(title: " "))
    #expect(configuration.backupServerURL.isEmpty)
    #expect(configuration.name == "stream-id")
  }

  @Test("Rejects LiveStreams without a usable RTMPS destination")
  func rejectsUnusableLiveStreams() {
    #expect(throws: YouTubeDualRTMPSConfigurationError.liveStreamNotFound) {
      try YouTubeLiveAPIClient.rtmpsStreamKeyConfiguration(from: nil)
    }
    #expect(throws: YouTubeDualRTMPSConfigurationError.liveStreamNotFound) {
      try YouTubeLiveAPIClient.rtmpsStreamKeyConfiguration(from: Self.stream(id: nil))
    }
    #expect(throws: YouTubeDualRTMPSConfigurationError.unsupportedIngestionType) {
      try YouTubeLiveAPIClient.rtmpsStreamKeyConfiguration(
        from: Self.stream(ingestionType: "dash"))
    }
    #expect(throws: YouTubeDualRTMPSConfigurationError.missingDestination) {
      try YouTubeLiveAPIClient.rtmpsStreamKeyConfiguration(from: Self.stream(key: nil))
    }
  }
}
