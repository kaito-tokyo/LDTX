// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import XCTest

@testable import LDTXMP4

final class MP4TimingBoxTests: XCTestCase {
  func testFragmentRescalesInheritedDurationsWithoutChangingPayload() throws {
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
      sourceTimescale: 48_000, destinationTimescale: 1_000_000_000,
      map: { CMTimeAdd($0, CMTime(value: 20_123, timescale: 1_000_000_000)) }, trackID: 1)
    let result = try MP4TimingBox.parse(clock.fragment(input))
    XCTAssertEqual(result.last?.payload, media)
    let moof = try XCTUnwrap(result.first)
    let traf = try XCTUnwrap(MP4TimingBox.parse(moof.payload).first)
    let rewritten = try MP4TimingBox.parse(traf.payload)
    let decode = try XCTUnwrap(rewritten.first { $0.type == MP4TimingBox.fourCC("tfdt") })
    let durations = try XCTUnwrap(rewritten.first { $0.type == MP4TimingBox.fourCC("trun") })
    XCTAssertEqual(try MP4TimingBox.read(decode.payload, at: 4, bytes: 8), 20_123)
    XCTAssertEqual(
      try MP4TimingBox.read(durations.payload, at: 8, bytes: 4),
      UInt64(try moof.encoded().count + 8))
    XCTAssertEqual(try MP4TimingBox.read(durations.payload, at: 12, bytes: 4), 21_333_333)
    XCTAssertEqual(try MP4TimingBox.read(durations.payload, at: 16, bytes: 4), 21_333_334)
    let absent = RecordingAudioFragmentClock(
      sourceTimescale: 48_000, destinationTimescale: 1_000_000_000,
      map: { _ in
        XCTFail("Absent audio track must not map timestamps")
        return .zero
      }, trackID: 2)
    XCTAssertEqual(try absent.fragment(input), input)
  }

  func testRoundTripPreservesUnknownPayloads() throws {
    let boxes = [
      MP4TimingBox(type: MP4TimingBox.fourCC("free"), payload: Data([0, 1, 255])),
      MP4TimingBox(type: MP4TimingBox.fourCC("mdat"), payload: Data(repeating: 42, count: 100)),
    ]
    let encoded = try boxes.reduce(into: Data()) { try $0.append($1.encoded()) }
    XCTAssertEqual(try MP4TimingBox.parse(encoded), boxes)
    XCTAssertEqual(try MP4TimingBox.parse(Data(encoded.dropFirst(11))), [boxes[1]])
  }

  func testExtendedAndRemainingSizes() throws {
    let extended = Data([0, 0, 0, 1, 102, 114, 101, 101, 0, 0, 0, 0, 0, 0, 0, 17, 42])
    let remaining = Data([0, 0, 0, 0, 102, 114, 101, 101, 42])
    XCTAssertEqual(try MP4TimingBox.parse(extended), try MP4TimingBox.parse(remaining))
  }

  func testRejectsMalformedSizes() {
    for bytes: [UInt8] in [
      [0], [0, 0, 0, 4, 102, 114, 101, 101],
      [0, 0, 0, 9, 102, 114, 101, 101],
      [0, 0, 0, 1, 102, 114, 101, 101],
      [0, 0, 0, 1, 102, 114, 101, 101, 255, 255, 255, 255, 255, 255, 255, 255],
    ] {
      XCTAssertThrowsError(try MP4TimingBox.parse(Data(bytes)))
    }
  }

  func testIntegerBoundsAndNonzeroDataIndices() throws {
    var data = Data([9, 0, 0, 0, 0, 9]).dropFirst().dropLast()
    try MP4TimingBox.write(0x1234_5678, to: &data, at: 0, bytes: 4)
    XCTAssertEqual(try MP4TimingBox.read(data, at: 0, bytes: 4), 0x1234_5678)
    XCTAssertThrowsError(try MP4TimingBox.read(data, at: -1, bytes: 4))
    XCTAssertThrowsError(try MP4TimingBox.read(data, at: Int.max, bytes: 8))
    XCTAssertThrowsError(try MP4TimingBox.write(UInt64.max, to: &data, at: 0, bytes: 4))
    XCTAssertThrowsError(try MP4TimingBox.write(0, to: &data, at: 1, bytes: 4))
  }
}
