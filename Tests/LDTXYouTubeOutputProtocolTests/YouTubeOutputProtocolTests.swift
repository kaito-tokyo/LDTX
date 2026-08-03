// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import LDTXYouTubeOutputProtocol

struct YouTubeOutputProtocolTests {
  @Test func derivesCodecStringFromSPSConstraintFlags() {
    let format = YouTubeOutputH264Format(
      parameterSets: [Data([0x67, 0x64, 0x0C, 0x2A]), Data([0x68, 0xEE])],
      nalUnitHeaderLength: 4,
      width: 1_920,
      height: 1_080)

    #expect(format.codecString == "avc1.640c2a")
    #expect(
      YouTubeOutputH264Format(
        parameterSets: [Data([0x68, 0xEE])], nalUnitHeaderLength: 4,
        width: 1_920, height: 1_080
      ).codecString == nil)
  }

  @Test func bootstrapRoundTrips() throws {
    let context = YouTubeOutputContext(sessionID: UUID(), revision: 3)
    let bootstrap = YouTubeOutputBootstrap(
      context: context,
      endpoint: URL(string: "https://upload.youtube.com/dash_upload?cid=test&file=")!,
      availabilityStartTime: Date(timeIntervalSince1970: 1_700_000_000),
      timescale: 1_000,
      startNumber: 37,
      mediaTemplate: "media$Number%09d$.mp4",
      representation: YouTubeOutputRepresentation(
        id: "1080p60",
        bandwidth: 8_128_000,
        width: 1_920,
        height: 1_080,
        frameRate: "60",
        codecs: "avc1.64002a,mp4a.40.2",
        audioSamplingRate: 48_000
      ),
      configurationFingerprint: "v1:1920:1080:60",
      initializationSegment: Data([9, 8, 7]),
      persistenceIdentifier: "broadcast-test",
      nextMediaTimeSeconds: 74.5
    )

    let encoded = try YouTubeOutputCoding.encode(bootstrap)
    let decoded = try YouTubeOutputCoding.decode(YouTubeOutputBootstrap.self, from: encoded)

    #expect(decoded == bootstrap)
    #expect(decoded.protocolVersion == LDTXYouTubeOutputServiceProcessInterfaces.protocolVersion)
  }

  @Test func checkpointReplyRoundTrips() throws {
    let context = YouTubeOutputContext(sessionID: UUID(), revision: 2)
    let reply = YouTubeOutputReply(
      context: context,
      sequence: 8,
      nextMediaSegmentNumber: 10,
      initializationSegment: Data([4, 5]),
      configurationFingerprint: "v1:test",
      availabilityStartTime: Date(timeIntervalSince1970: 1_700_000_000.123),
      eventDescription: "committed"
    )

    let encoded = try YouTubeOutputCoding.encode(reply)
    let decoded = try YouTubeOutputCoding.decode(YouTubeOutputReply.self, from: encoded)

    #expect(decoded == reply)
  }

  @Test func resetRequestRoundTrips() throws {
    let request = YouTubeOutputResetRequest(
      context: YouTubeOutputContext(sessionID: UUID(), revision: 7),
      reason: "DASH pipeline state is no longer recoverable.",
      nextMediaSegmentNumber: 23,
      initializationSegment: Data([0x01, 0x02]),
      configurationFingerprint: "v1:test",
      availabilityStartTime: Date(timeIntervalSince1970: 1_700_000_000.123),
      nextMediaTimeSeconds: 46.25
    )

    let encoded = try YouTubeOutputCoding.encode(request)
    let decoded = try YouTubeOutputCoding.decode(YouTubeOutputResetRequest.self, from: encoded)

    #expect(decoded == request)
  }

  @Test func h264AndPCMMediaBatchRoundTripsAsProtobuf() throws {
    let time = YouTubeOutputMediaTime(value: 90_000, timescale: 90_000)
    let batch = YouTubeOutputMediaBatch(
      context: YouTubeOutputContext(sessionID: UUID(), revision: 5),
      sequence: 12,
      videoFormat: YouTubeOutputH264Format(
        parameterSets: [Data([0x67, 0x64]), Data([0x68, 0xEE])],
        nalUnitHeaderLength: 4,
        width: 1_920,
        height: 1_080
      ),
      video: [
        YouTubeOutputH264AccessUnit(
          presentationTime: time,
          decodeTime: time,
          duration: YouTubeOutputMediaTime(value: 1_500, timescale: 90_000),
          isKeyFrame: true,
          avccData: Data(),
          sharedMemory: YouTubeOutputSharedMemorySlice(
            slot: 2, generation: 7, offset: 128, length: 6)
        )
      ],
      audio: [
        YouTubeOutputPCMBuffer(
          presentationTime: YouTubeOutputMediaTime(value: 48_000, timescale: 48_000),
          duration: YouTubeOutputMediaTime(value: 1_024, timescale: 48_000),
          sampleRate: 48_000,
          channelCount: 2,
          frameCount: 1_024,
          sampleFormat: .float32Interleaved,
          data: Data(repeating: 0, count: 1_024 * 2 * 4)
        )
      ]
    )

    let encoded = try YouTubeOutputCoding.encode(batch)
    let decoded = try YouTubeOutputCoding.decode(YouTubeOutputMediaBatch.self, from: encoded)

    #expect(encoded.first != UInt8(ascii: "{"))
    #expect(decoded == batch)
  }

  @Test func sequenceGateRejectsDuplicateSkippedAndStaleRevisionWithoutAdvancing() throws {
    let context = YouTubeOutputContext(sessionID: UUID(), revision: 5)
    var gate = YouTubeOutputSequenceGate(context: context)

    try gate.accept(YouTubeOutputMediaBatch(context: context, sequence: 0))
    #expect(gate.expectedSequence == 1)

    #expect(throws: YouTubeOutputSequenceError.unexpectedSequence(expected: 1, actual: 0)) {
      try gate.accept(YouTubeOutputMediaBatch(context: context, sequence: 0))
    }
    #expect(throws: YouTubeOutputSequenceError.unexpectedSequence(expected: 1, actual: 2)) {
      try gate.accept(YouTubeOutputMediaBatch(context: context, sequence: 2))
    }
    #expect(throws: YouTubeOutputSequenceError.staleContext) {
      try gate.accept(
        YouTubeOutputMediaBatch(
          context: YouTubeOutputContext(sessionID: context.sessionID, revision: 4),
          sequence: 1))
    }
    #expect(gate.expectedSequence == 1)

    try gate.accept(YouTubeOutputMediaBatch(context: context, sequence: 1))
    #expect(gate.expectedSequence == 2)
  }
}
