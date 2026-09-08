// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum MP4TimingBoxError: Error {
  case malformedBox
  case invalidStructure(String)

  static func malformed(file: StaticString = #fileID, line: UInt = #line) -> Self {
    .invalidStructure("\(file):\(line)")
  }
  case integerOverflow
}

/// Bounded ISO BMFF box access for the recording timing rewrite. Unknown boxes
/// remain opaque; callers explicitly choose which container payloads to parse.
struct MP4TimingBox: Equatable {
  let type: UInt32
  var payload: Data

  static func fourCC(_ text: String) -> UInt32 {
    precondition(text.utf8.count == 4)
    return text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
  }

  static func parse(_ data: Data) throws -> [Self] {
    let data = Data(data)
    var offset = 0
    var boxes: [Self] = []
    while offset < data.count {
      guard data.count - offset >= 8 else { throw MP4TimingBoxError.malformed() }
      let shortSize = try read(data, at: offset, bytes: 4)
      let type = UInt32(try read(data, at: offset + 4, bytes: 4))
      let headerSize: Int
      let size: UInt64
      switch shortSize {
      case 0:
        headerSize = 8
        size = UInt64(data.count - offset)
      case 1:
        headerSize = 16
        size = try read(data, at: offset + 8, bytes: 8)
      default:
        headerSize = 8
        size = shortSize
      }
      guard size >= UInt64(headerSize), size <= UInt64(data.count - offset) else {
        throw MP4TimingBoxError.malformed()
      }
      let end = offset + Int(size)
      boxes.append(Self(type: type, payload: Data(data[(offset + headerSize)..<end])))
      offset = end
    }
    return boxes
  }

  func encoded() throws -> Data {
    guard payload.count <= Int(UInt32.max) - 8 else {
      throw MP4TimingBoxError.integerOverflow
    }
    var result = Data(repeating: 0, count: 8)
    try Self.write(UInt64(payload.count + 8), to: &result, at: 0, bytes: 4)
    try Self.write(UInt64(type), to: &result, at: 4, bytes: 4)
    result.append(payload)
    return result
  }

  static func read(_ data: Data, at offset: Int, bytes: Int) throws -> UInt64 {
    guard (1...8).contains(bytes), offset >= 0, offset <= data.count,
      bytes <= data.count - offset
    else { throw MP4TimingBoxError.malformed() }
    var result: UInt64 = 0
    for index in offset..<(offset + bytes) {
      result = (result << 8) | UInt64(data[data.startIndex + index])
    }
    return result
  }

  static func write(_ value: UInt64, to data: inout Data, at offset: Int, bytes: Int) throws {
    guard (1...8).contains(bytes), offset >= 0, offset <= data.count,
      bytes <= data.count - offset
    else { throw MP4TimingBoxError.malformed() }
    guard bytes == 8 || value < (UInt64(1) << (bytes * 8)) else {
      throw MP4TimingBoxError.integerOverflow
    }
    for index in 0..<bytes {
      data[data.startIndex + offset + index] = UInt8(
        truncatingIfNeeded: value >> ((bytes - index - 1) * 8))
    }
  }
}
