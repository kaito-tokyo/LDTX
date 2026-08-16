// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import LDTXYouTubeRTMPS

struct RTMPEncodingTests {
  @Test func amfCommandEncodingIsDeterministic() {
    let data = AMF0Encoder.encode([.string("publish"), .number(0), .null])
    #expect(data.prefix(10) == Data([2, 0, 7]) + Data("publish".utf8))
    #expect(data.last == 5)
  }

  @Test func chunkEncoderSplitsPayloadAndUsesContinuationHeader() {
    let data = RTMPChunkEncoder(chunkSize: 4).encode(
      chunkStreamID: 6, messageTypeID: 9, messageStreamID: 1,
      timestamp: 10, payload: Data(0..<10))
    #expect(data[0] == 6)
    #expect(data[16] == 0xC6)
    #expect(data[21] == 0xC6)
  }

  @Test func chunkEncoderWritesExtendedTimestampOnEveryChunk() {
    let data = RTMPChunkEncoder(chunkSize: 2).encode(
      chunkStreamID: 4, messageTypeID: 8, messageStreamID: 1,
      timestamp: 0x0102_0304, payload: Data([1, 2, 3]))
    #expect(data[1...3] == Data([0xFF, 0xFF, 0xFF]))
    #expect(data[12...15] == Data([1, 2, 3, 4]))
    #expect(data[18] == 0xC4)
    #expect(data[19...22] == Data([1, 2, 3, 4]))
  }

  @Test func destinationRequiresSecureShape() throws {
    _ = try YouTubeRTMPSDestination(
      ingestionURL: #require(URL(string: "rtmps://a.rtmps.youtube.com/live2")),
      streamName: "secret")
    #expect(throws: YouTubeRTMPSError.invalidDestination) {
      try YouTubeRTMPSDestination(
        ingestionURL: #require(URL(string: "rtmp://example.com/live")),
        streamName: "secret")
    }
  }

  @Test func dualDestinationsRequireDifferentStreamNames() throws {
    let primary = try YouTubeRTMPSDestination(
      ingestionURL: #require(URL(string: "rtmps://a.rtmps.youtube.com/live2")),
      streamName: "secret")
    let backup = try YouTubeRTMPSDestination(
      ingestionURL: #require(URL(string: "rtmps://b.rtmps.youtube.com/live2")),
      streamName: "secret")
    #expect(throws: YouTubeRTMPSError.self) {
      try YouTubeDualRTMPSDestinations(landscape: primary, portrait: backup)
    }
  }
}
