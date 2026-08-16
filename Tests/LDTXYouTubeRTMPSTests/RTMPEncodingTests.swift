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

  @Test func inboundDecoderReassemblesFragmentedAndCompressedChunks() throws {
    let firstPayload = Data(repeating: 0x41, count: 130)
    let first = RTMPChunkEncoder(chunkSize: 128).encode(
      chunkStreamID: 3, messageTypeID: 20, messageStreamID: 1,
      timestamp: 10, payload: firstPayload)
    let pingPayload = Data([0, 6, 1, 2, 3, 4])
    let ping = RTMPChunkEncoder().encode(
      chunkStreamID: 2, messageTypeID: 4, messageStreamID: 0,
      timestamp: 11, payload: pingPayload)
    var decoder = RTMPChunkDecoder()
    var messages: [RTMPInboundMessage] = []
    let combined = first + ping
    for byte in combined {
      messages += try decoder.append(Data([byte]))
    }
    #expect(messages.count == 2)
    #expect(messages[0].payload == firstPayload)
    #expect(messages[1].typeID == 4)
    #expect(messages[1].payload == pingPayload)
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
