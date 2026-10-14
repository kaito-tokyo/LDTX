// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
@testable import LDTXMP4
import Testing

extension OutputTestSuite {
  @Suite
  struct MP4TimingBoxUnitTestSuite {
    @Test func fragmentRescalesInheritedDurationsWithoutChangingPayload() throws {
      func box(_ type: String, _ payload: Data) throws -> Data {
        try MP4TimingBox(type: MP4TimingBox.fourCC(type), payload: payload).encoded()
      }
      var header = Data(repeating: 0, count: 12)
      try MP4TimingBox.write(0x20008, to: &header, at: 0, bytes: 4)
      try MP4TimingBox.write(1, to: &header, at: 4, bytes: 4)
      try MP4TimingBox.write(1024, to: &header, at: 8, bytes: 4)
      var run = Data(repeating: 0, count: 12)
      try MP4TimingBox.write(1, to: &run, at: 0, bytes: 4)
      try MP4TimingBox.write(2, to: &run, at: 4, bytes: 4)
      // moof(8) + traf(8) + tfhd(20) + tfdt(16) + trun(20) + mdat header(8).
      try MP4TimingBox.write(80, to: &run, at: 8, bytes: 4)
      let fields =
        try box("tfhd", header) + box("tfdt", Data(repeating: 0, count: 8)) + box("trun", run)
      let media = Data([17, 23, 41, 89])
      let input = try box("moof", box("traf", fields)) + box("mdat", media)
      let clock = RecordingAudioFragmentClock(
        sourceTimescale: 48_000, destinationTimescale: 48_000,
        map: { CMTimeAdd($0, CMTime(value: 1, timescale: 48_000)) }, trackID: 1)
      let result = try MP4TimingBox.parse(clock.fragment(input))
      #expect(result.last?.payload == media)
      let moof = try #require(result.first)
      let traf = try #require(MP4TimingBox.parse(moof.payload).first)
      let rewritten = try MP4TimingBox.parse(traf.payload)
      let decode = try #require(rewritten.first { $0.type == MP4TimingBox.fourCC("tfdt") })
      let durations = try #require(rewritten.first { $0.type == MP4TimingBox.fourCC("trun") })
      #expect(try MP4TimingBox.read(decode.payload, at: 4, bytes: 8) == 1)
      #expect(
        try MP4TimingBox.read(durations.payload, at: 8, bytes: 4)
          == UInt64(try moof.encoded().count + 8))
      #expect(try MP4TimingBox.read(durations.payload, at: 12, bytes: 4) == 1_024)
      #expect(try MP4TimingBox.read(durations.payload, at: 16, bytes: 4) == 1_024)
      let absent = RecordingAudioFragmentClock(
        sourceTimescale: 48_000, destinationTimescale: 48_000,
        map: { _ in
          Issue.record("Absent audio track must not map timestamps")
          return .zero
        }, trackID: 2)
      #expect(try absent.fragment(input) == input)
    }

    @Test func initializationUsesSampleBasedAudioAndCommonMovieClocks() throws {
      func box(_ type: String, _ payload: Data) throws -> Data {
        try MP4TimingBox(type: MP4TimingBox.fourCC(type), payload: payload).encoded()
      }
      func track(
        id: UInt32, mediaTimescale: UInt32, handlerType: String, additionalBoxes: Data = Data()
      ) throws -> Data {
        var header = Data(repeating: 0, count: 24)
        try MP4TimingBox.write(UInt64(id), to: &header, at: 12, bytes: 4)
        try MP4TimingBox.write(600, to: &header, at: 20, bytes: 4)
        var mediaHeader = Data(repeating: 0, count: 20)
        try MP4TimingBox.write(UInt64(mediaTimescale), to: &mediaHeader, at: 12, bytes: 4)
        try MP4TimingBox.write(UInt64(mediaTimescale), to: &mediaHeader, at: 16, bytes: 4)
        var handler = Data(repeating: 0, count: 12)
        try MP4TimingBox.write(
          UInt64(MP4TimingBox.fourCC(handlerType)), to: &handler, at: 8, bytes: 4)
        let media = try box("mdia", box("mdhd", mediaHeader) + box("hdlr", handler))
        return try box("trak", box("tkhd", header) + media + additionalBoxes)
      }
      var movieHeader = Data(repeating: 0, count: 20)
      try MP4TimingBox.write(600, to: &movieHeader, at: 12, bytes: 4)
      try MP4TimingBox.write(600, to: &movieHeader, at: 16, bytes: 4)
      var editList = Data(repeating: 0, count: 20)
      try MP4TimingBox.write(1, to: &editList, at: 4, bytes: 4)
      try MP4TimingBox.write(600, to: &editList, at: 8, bytes: 4)
      try MP4TimingBox.write(896, to: &editList, at: 12, bytes: 4)
      let audioEdit = try box("edts", box("elst", editList))
      let audio = try track(
        id: 2, mediaTimescale: 48_000, handlerType: "soun", additionalBoxes: audioEdit)
      let video = try track(id: 1, mediaTimescale: 600, handlerType: "vide")
      let input = try box("moov", box("mvhd", movieHeader) + video + audio)
      let clock = RecordingAudioFragmentClock(
        sourceTimescale: 48_000, destinationTimescale: 48_000,
        map: { $0 }, trackID: 2)
      let output = try MP4TimingBox.parse(clock.initialization(input))
      let movie = try #require(output.first { $0.type == MP4TimingBox.fourCC("moov") })
      let children = try MP4TimingBox.parse(movie.payload)
      let rewrittenMovieHeader = try #require(
        children.first { $0.type == MP4TimingBox.fourCC("mvhd") })
      #expect(try MP4TimingBox.read(rewrittenMovieHeader.payload, at: 12, bytes: 4) == 48_000)
      #expect(try MP4TimingBox.read(rewrittenMovieHeader.payload, at: 16, bytes: 4) == 48_000)
      let rewrittenVideo = try #require(
        children.first { $0.type == MP4TimingBox.fourCC("trak") })
      let videoMedia = try #require(
        MP4TimingBox.parse(rewrittenVideo.payload).first { $0.type == MP4TimingBox.fourCC("mdia") })
      let videoHeader = try #require(
        MP4TimingBox.parse(videoMedia.payload).first { $0.type == MP4TimingBox.fourCC("mdhd") })
      #expect(try MP4TimingBox.read(videoHeader.payload, at: 12, bytes: 4) == 600)
      let rewrittenAudio = try #require(
        children.last { $0.type == MP4TimingBox.fourCC("trak") })
      let audioChildren = try MP4TimingBox.parse(rewrittenAudio.payload)
      let audioMedia = try #require(audioChildren.first { $0.type == MP4TimingBox.fourCC("mdia") })
      let audioHeader = try #require(
        MP4TimingBox.parse(audioMedia.payload).first { $0.type == MP4TimingBox.fourCC("mdhd") })
      #expect(try MP4TimingBox.read(audioHeader.payload, at: 12, bytes: 4) == 48_000)
      let edit = try #require(
        audioChildren.first { $0.type == MP4TimingBox.fourCC("edts") })
      let entry = try #require(
        MP4TimingBox.parse(edit.payload).first { $0.type == MP4TimingBox.fourCC("elst") })
      #expect(try MP4TimingBox.read(entry.payload, at: 8, bytes: 4) == 48_000)
      #expect(try MP4TimingBox.read(entry.payload, at: 12, bytes: 4) == 896)
    }

    @Test func roundTripPreservesUnknownPayloads() throws {
      let boxes = [
        MP4TimingBox(type: MP4TimingBox.fourCC("free"), payload: Data([0, 1, 255])),
        MP4TimingBox(type: MP4TimingBox.fourCC("mdat"), payload: Data(repeating: 42, count: 100)),
      ]
      let encoded = try boxes.reduce(into: Data()) { try $0.append($1.encoded()) }
      #expect(try MP4TimingBox.parse(encoded) == boxes)
      #expect(try MP4TimingBox.parse(Data(encoded.dropFirst(11))) == [boxes[1]])
    }

    @Test func extendedAndRemainingSizes() throws {
      let extended = Data([0, 0, 0, 1, 102, 114, 101, 101, 0, 0, 0, 0, 0, 0, 0, 17, 42])
      let remaining = Data([0, 0, 0, 0, 102, 114, 101, 101, 42])
      #expect(try MP4TimingBox.parse(extended) == MP4TimingBox.parse(remaining))
    }

    @Test func rejectsMalformedSizes() {
      for bytes: [UInt8] in [
        [0], [0, 0, 0, 4, 102, 114, 101, 101],
        [0, 0, 0, 9, 102, 114, 101, 101],
        [0, 0, 0, 1, 102, 114, 101, 101],
        [0, 0, 0, 1, 102, 114, 101, 101, 255, 255, 255, 255, 255, 255, 255, 255],
      ] {
        #expect(throws: (any Error).self) { try MP4TimingBox.parse(Data(bytes)) }
      }
    }

    @Test func integerBoundsAndNonzeroDataIndices() throws {
      var data = Data([9, 0, 0, 0, 0, 9]).dropFirst().dropLast()
      try MP4TimingBox.write(0x1234_5678, to: &data, at: 0, bytes: 4)
      #expect(try MP4TimingBox.read(data, at: 0, bytes: 4) == 0x1234_5678)
      #expect(throws: (any Error).self) { try MP4TimingBox.read(data, at: -1, bytes: 4) }
      #expect(throws: (any Error).self) { try MP4TimingBox.read(data, at: Int.max, bytes: 8) }
      #expect(throws: (any Error).self) {
        try MP4TimingBox.write(UInt64.max, to: &data, at: 0, bytes: 4)
      }
      #expect(throws: (any Error).self) { try MP4TimingBox.write(0, to: &data, at: 1, bytes: 4) }
    }
  }
}
