// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import LDTXYouTubeRTMPS
import Testing

extension OutputTestSuite {
  @Suite
  struct FLVPacketEncoderUnitTestSuite {
    @Test("LUB-1016: Metadata describes the media without destination data")
    func metadataDescribesTheMediaWithoutDestinationData() {
      let packet = FLVPacketEncoder.metadata(
        videoFormat: YouTubeRTMPSVideoFormat(
          sequenceParameterSet: Data([0x67, 0x64, 0, 0x2A]),
          pictureParameterSet: Data([0x68, 0xEE]),
          width: 1_920,
          height: 1_080,
          frameRate: 60,
          bitRate: 12_000_000),
        audioFormat: YouTubeRTMPSAudioFormat(
          audioSpecificConfig: Data([0x11, 0x90]),
          sampleRate: 48_000,
          channelCount: 2,
          bitRate: 128_000))

      #expect(packet.typeID == 18)
      #expect(packet.timestamp == 0)
      #expect(packet.payload.range(of: Data("@setDataFrame".utf8)) != nil)
      #expect(packet.payload.range(of: Data("onMetaData".utf8)) != nil)
      #expect(packet.payload.range(of: Data("width".utf8)) != nil)
      #expect(packet.payload.range(of: Data("framerate".utf8)) != nil)
      let markerOffset = 1 + 2 + "@setDataFrame".utf8.count + 1 + 2 + "onMetaData".utf8.count
      #expect(packet.payload[markerOffset] == 8)
      #expect(packet.payload.range(of: Data("secret".utf8)) == nil)
    }

    @Test("LUB-1016: Avc sequence header contains parameter sets")
    func avcSequenceHeaderContainsParameterSets() throws {
      let packet = try FLVPacketEncoder.avcSequenceHeader(
        YouTubeRTMPSVideoFormat(
          sequenceParameterSet: Data([0x67, 0x64, 0, 0x2A]),
          pictureParameterSet: Data([0x68, 0xEE, 0x3C, 0x80])))
      #expect(packet.typeID == 9)
      #expect(packet.timestamp == 0)
      #expect(packet.payload.prefix(5) == Data([0x17, 0, 0, 0, 0]))
      #expect(packet.payload.suffix(4) == Data([0x68, 0xEE, 0x3C, 0x80]))
    }

    @Test("LUB-1016: Avc sequence header accepts sliced parameter sets")
    func avcSequenceHeaderAcceptsSlicedParameterSets() throws {
      let storage = Data([0xFF, 0x67, 0x64, 0, 0x2A])
      let sps = storage[1...]
      let format = YouTubeRTMPSVideoFormat(
        sequenceParameterSet: sps, pictureParameterSet: Data([0x68, 0xEE]))
      let packet = try FLVPacketEncoder.avcSequenceHeader(format)
      #expect(packet.payload.contains(0x67))
    }

    @Test("LUB-1016: Video uses DTS and signed composition time")
    func videoUsesDTSAndSignedCompositionTime() throws {
      let packet = try FLVPacketEncoder.video(
        YouTubeRTMPSVideoSample(
          avccData: Data([0, 0, 0, 1, 0x65]),
          presentationTime: YouTubeRTMPSTime(milliseconds: 1_033),
          decodeTime: YouTubeRTMPSTime(milliseconds: 1_000),
          isKeyFrame: true))
      #expect(packet.timestamp == 1_000)
      #expect(packet.payload.prefix(5) == Data([0x17, 1, 0, 0, 33]))
    }

    @Test("LUB-1016: AAC packets use sequence and raw packet types")
    func aacPacketsUseSequenceAndRawPacketTypes() throws {
      let header = try FLVPacketEncoder.aacSequenceHeader(
        YouTubeRTMPSAudioFormat(audioSpecificConfig: Data([0x11, 0x90])))
      let sample = try FLVPacketEncoder.audio(
        YouTubeRTMPSAudioSample(
          rawAACData: Data([1, 2, 3]),
          presentationTime: YouTubeRTMPSTime(milliseconds: 24)))
      #expect(header.payload == Data([0xAF, 0, 0x11, 0x90]))
      #expect(sample.payload == Data([0xAF, 1, 1, 2, 3]))
      #expect(sample.timestamp == 24)
    }

    @Test("LUB-1016: Rejects empty AAC configuration") func rejectsEmptyAACConfiguration() {
      #expect(throws: YouTubeRTMPSError.self) {
        try FLVPacketEncoder.aacSequenceHeader(
          YouTubeRTMPSAudioFormat(audioSpecificConfig: Data()))
      }
    }

    @Test("LUB-1016: Rejects empty AAC sample") func rejectsEmptyAACSample() {
      #expect(throws: YouTubeRTMPSError.self) {
        try FLVPacketEncoder.audio(
          YouTubeRTMPSAudioSample(
            rawAACData: Data(), presentationTime: .init(milliseconds: 0)))
      }
    }

    @Test("LUB-1016: Rejects out of range timestamps") func rejectsOutOfRangeTimestamps() {
      #expect(throws: YouTubeRTMPSError.invalidTimestamp) {
        try FLVPacketEncoder.video(
          YouTubeRTMPSVideoSample(
            avccData: Data([1]),
            presentationTime: YouTubeRTMPSTime(milliseconds: -1),
            decodeTime: YouTubeRTMPSTime(milliseconds: -1),
            isKeyFrame: false))
      }
    }

    @Test("LUB-1016: Timestamps wrap at u int32 boundary") func timestampsWrapAtUInt32Boundary()
      throws
    {
      let packet = try FLVPacketEncoder.audio(
        YouTubeRTMPSAudioSample(
          rawAACData: Data([1]),
          presentationTime: .init(milliseconds: Int64(UInt32.max) + 1)))
      #expect(packet.timestamp == 0)
    }

    @Test("LUB-1016: Rejects overflowing composition time") func rejectsOverflowingCompositionTime()
    {
      #expect(throws: YouTubeRTMPSError.invalidTimestamp) {
        try FLVPacketEncoder.video(
          YouTubeRTMPSVideoSample(
            avccData: Data([0, 0, 0, 1, 0x65]),
            presentationTime: .init(milliseconds: .min), decodeTime: .init(milliseconds: 1),
            isKeyFrame: true))
      }
    }
  }
}
