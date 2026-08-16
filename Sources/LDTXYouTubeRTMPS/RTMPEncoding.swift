// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum AMF0Value: Sendable {
  case number(Double)
  case boolean(Bool)
  case string(String)
  case object([(String, AMF0Value)])
  case null
}

enum AMF0Encoder {
  static func encode(_ values: [AMF0Value]) -> Data {
    values.reduce(into: Data()) { $0.append(encode($1)) }
  }

  static func encode(_ value: AMF0Value) -> Data {
    var data = Data()
    switch value {
    case .number(let number):
      data.append(0)
      var bits = number.bitPattern.bigEndian
      withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    case .boolean(let value):
      data.append(contentsOf: [1, value ? 1 : 0])
    case .string(let string):
      let bytes = Data(string.utf8)
      data.append(2)
      data.appendUInt16(UInt16(clamping: bytes.count))
      data.append(bytes.prefix(Int(UInt16.max)))
    case .object(let entries):
      data.append(3)
      for (key, value) in entries {
        let bytes = Data(key.utf8)
        data.appendUInt16(UInt16(clamping: bytes.count))
        data.append(bytes.prefix(Int(UInt16.max)))
        data.append(encode(value))
      }
      data.append(contentsOf: [0, 0, 9])
    case .null:
      data.append(5)
    }
    return data
  }
}

struct RTMPChunkEncoder: Sendable {
  var chunkSize = 128

  func encode(
    chunkStreamID: UInt8,
    messageTypeID: UInt8,
    messageStreamID: UInt32,
    timestamp: UInt32,
    payload: Data
  ) -> Data {
    precondition((2...63).contains(chunkStreamID))
    let usesExtendedTimestamp = timestamp >= 0x00FF_FFFF
    var output = Data()
    var offset = 0
    var first = true
    repeat {
      output.append((first ? 0 : 3) << 6 | chunkStreamID)
      if first {
        output.appendUInt24(usesExtendedTimestamp ? 0x00FF_FFFF : timestamp)
        output.appendUInt24(UInt32(payload.count))
        output.append(messageTypeID)
        output.appendLittleEndianUInt32(messageStreamID)
      }
      if usesExtendedTimestamp { output.appendUInt32(timestamp) }
      let count = min(chunkSize, payload.count - offset)
      if count > 0 { output.append(payload[offset..<(offset + count)]) }
      offset += count
      first = false
    } while offset < payload.count
    return output
  }
}
