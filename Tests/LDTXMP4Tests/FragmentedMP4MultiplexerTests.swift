// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import LDTXMP4

final class FragmentedMP4MultiplexerTests: XCTestCase {
  func testMediaPreservesImplicitOffsetForContiguousLaterRun() throws {
    let video = mediaSegment(
      trackID: 1,
      runs: [trackRun(dataOffset: 100), trackRun(dataOffset: nil)],
      mediaPayload: Data(repeating: 0x11, count: 16))
    let audio = mediaSegment(
      trackID: 1,
      runs: [trackRun(dataOffset: 120)],
      mediaPayload: Data(repeating: 0x22, count: 8))

    let output = try FragmentedMP4Multiplexer.media(video: video, audio: audio)
    let topLevel = try boxes(in: output)
    let movieFragment = try XCTUnwrap(topLevel.first { $0.type == "moof" })
    let trackFragments = try boxes(in: movieFragment.payload).filter { $0.type == "traf" }
    let videoRuns = try boxes(in: try XCTUnwrap(trackFragments.first).payload)
      .filter { $0.type == "trun" }

    XCTAssertEqual(videoRuns.count, 2)
    XCTAssertEqual(try uint32(in: videoRuns[0].payload, at: 0) & 0x00FF_FFFF, 0x000001)
    XCTAssertEqual(try uint32(in: videoRuns[1].payload, at: 0) & 0x00FF_FFFF, 0)
    XCTAssertEqual(videoRuns[1].payload.count, 8)
  }

  func testMediaRequiresExplicitOffsetOnFirstRun() throws {
    let video = mediaSegment(
      trackID: 1,
      runs: [trackRun(dataOffset: nil)],
      mediaPayload: Data(repeating: 0x11, count: 8))
    let audio = mediaSegment(
      trackID: 1,
      runs: [trackRun(dataOffset: 100)],
      mediaPayload: Data(repeating: 0x22, count: 8))

    XCTAssertThrowsError(try FragmentedMP4Multiplexer.media(video: video, audio: audio)) {
      guard case FragmentedMP4MultiplexerError.missingDataOffset = $0 else {
        return XCTFail("unexpected error: \($0)")
      }
    }
  }

  private func mediaSegment(
    trackID: UInt32,
    runs: [Data],
    mediaPayload: Data
  ) -> Data {
    let trackHeader = box(type: "tfhd", payload: uint32(0).appending(uint32(trackID)))
    let trackFragment = box(type: "traf", payload: ([trackHeader] + runs).joined())
    let movieFragmentHeader = box(type: "mfhd", payload: uint32(0).appending(uint32(1)))
    let movieFragment = box(
      type: "moof", payload: [movieFragmentHeader, trackFragment].joined())
    return [movieFragment, box(type: "mdat", payload: mediaPayload)].joined()
  }

  private func trackRun(dataOffset: Int32?) -> Data {
    var payload = uint32(dataOffset == nil ? 0 : 0x000001)
    payload.append(uint32(0))
    if let dataOffset {
      payload.append(uint32(UInt32(bitPattern: dataOffset)))
    }
    return box(type: "trun", payload: payload)
  }

  private func box(type: String, payload: Data) -> Data {
    var result = uint32(UInt32(payload.count + 8))
    result.append(type.data(using: .ascii)!)
    result.append(payload)
    return result
  }

  private func boxes(in data: Data) throws -> [(type: String, payload: Data)] {
    var result: [(type: String, payload: Data)] = []
    var offset = 0
    while offset < data.count {
      let size = Int(try uint32(in: data, at: offset))
      guard size >= 8, offset + size <= data.count else {
        throw TestError.invalidBox
      }
      let typeData = Data(data[(offset + 4)..<(offset + 8)])
      guard let type = String(data: typeData, encoding: .ascii) else {
        throw TestError.invalidBox
      }
      result.append((type, Data(data[(offset + 8)..<(offset + size)])))
      offset += size
    }
    return result
  }

  private func uint32(_ value: UInt32) -> Data {
    Data([
      UInt8(truncatingIfNeeded: value >> 24),
      UInt8(truncatingIfNeeded: value >> 16),
      UInt8(truncatingIfNeeded: value >> 8),
      UInt8(truncatingIfNeeded: value),
    ])
  }

  private func uint32(in data: Data, at offset: Int) throws -> UInt32 {
    guard offset >= 0, offset + 4 <= data.count else { throw TestError.invalidBox }
    return data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
  }
}

private enum TestError: Error {
  case invalidBox
}

private extension Data {
  func appending(_ other: Data) -> Data {
    var result = self
    result.append(other)
    return result
  }
}

private extension Array where Element == Data {
  func joined() -> Data {
    reduce(into: Data()) { $0.append($1) }
  }
}
