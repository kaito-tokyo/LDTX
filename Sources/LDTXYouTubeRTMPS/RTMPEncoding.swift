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

struct RTMPInboundMessage: Sendable {
  var typeID: UInt8
  var streamID: UInt32
  var timestamp: UInt32
  var payload: Data
}

struct RTMPChunkDecoder: Sendable {
  private struct ChunkState: Sendable {
    var timestamp: UInt32
    var timestampDelta: UInt32
    var messageLength: Int
    var typeID: UInt8
    var streamID: UInt32
    var usesExtendedTimestamp: Bool
    var payload: Data
  }

  private var buffer = Data()
  private var states: [Int: ChunkState] = [:]
  private(set) var chunkSize = 128

  mutating func append(_ data: Data) throws -> [RTMPInboundMessage] {
    buffer.append(data)
    var messages: [RTMPInboundMessage] = []
    while let result = try decodeChunk() {
      guard let message = result else { continue }
      if message.typeID == 1, let size = Self.uint32(message.payload, at: 0) {
        let value = Int(size & 0x7FFF_FFFF)
        guard value > 0 else { throw YouTubeRTMPSError.protocolFailure("chunk size") }
        chunkSize = value
      }
      messages.append(message)
    }
    return messages
  }

  private mutating func decodeChunk() throws -> RTMPInboundMessage?? {
    guard !buffer.isEmpty else { return nil }
    var offset = 0
    let first = buffer[offset]
    offset += 1
    let format = Int(first >> 6)
    var chunkStreamID = Int(first & 0x3F)
    if chunkStreamID == 0 {
      guard buffer.count >= offset + 1 else { return nil }
      chunkStreamID = 64 + Int(buffer[offset])
      offset += 1
    } else if chunkStreamID == 1 {
      guard buffer.count >= offset + 2 else { return nil }
      chunkStreamID = 64 + Int(buffer[offset]) + Int(buffer[offset + 1]) * 256
      offset += 2
    }

    let previous = states[chunkStreamID]
    var state: ChunkState
    switch format {
    case 0:
      guard buffer.count >= offset + 11 else { return nil }
      let timestampField = Self.uint24(buffer, at: offset)!
      let length = Int(Self.uint24(buffer, at: offset + 3)!)
      let typeID = buffer[offset + 6]
      let streamID = Self.littleEndianUInt32(buffer, at: offset + 7)!
      offset += 11
      let extended = timestampField == 0x00FF_FFFF
      var timestamp = timestampField
      if extended {
        guard buffer.count >= offset + 4 else { return nil }
        timestamp = Self.uint32(buffer, at: offset)!
        offset += 4
      }
      state = ChunkState(
        timestamp: timestamp, timestampDelta: 0, messageLength: length, typeID: typeID,
        streamID: streamID, usesExtendedTimestamp: extended, payload: Data())
    case 1:
      guard let previous, buffer.count >= offset + 7 else { return nil }
      let deltaField = Self.uint24(buffer, at: offset)!
      let length = Int(Self.uint24(buffer, at: offset + 3)!)
      let typeID = buffer[offset + 6]
      offset += 7
      let extended = deltaField == 0x00FF_FFFF
      var delta = deltaField
      if extended {
        guard buffer.count >= offset + 4 else { return nil }
        delta = Self.uint32(buffer, at: offset)!
        offset += 4
      }
      state = ChunkState(
        timestamp: previous.timestamp &+ delta, timestampDelta: delta, messageLength: length,
        typeID: typeID, streamID: previous.streamID, usesExtendedTimestamp: extended,
        payload: Data())
    case 2:
      guard let previous, buffer.count >= offset + 3 else { return nil }
      let deltaField = Self.uint24(buffer, at: offset)!
      offset += 3
      let extended = deltaField == 0x00FF_FFFF
      var delta = deltaField
      if extended {
        guard buffer.count >= offset + 4 else { return nil }
        delta = Self.uint32(buffer, at: offset)!
        offset += 4
      }
      state = previous
      state.timestamp = previous.timestamp &+ delta
      state.timestampDelta = delta
      state.usesExtendedTimestamp = extended
      state.payload = Data()
    case 3:
      guard let previous else { throw YouTubeRTMPSError.protocolFailure("chunk header") }
      state = previous
      if previous.payload.count == previous.messageLength {
        state.timestamp = previous.timestamp &+ previous.timestampDelta
        state.payload = Data()
      }
      if state.usesExtendedTimestamp {
        guard buffer.count >= offset + 4 else { return nil }
        offset += 4
      }
    default:
      throw YouTubeRTMPSError.protocolFailure("chunk header")
    }

    guard state.messageLength >= state.payload.count else {
      throw YouTubeRTMPSError.protocolFailure("chunk length")
    }
    let count = min(chunkSize, state.messageLength - state.payload.count)
    guard buffer.count >= offset + count else { return nil }
    if count > 0 { state.payload.append(buffer[offset..<(offset + count)]) }
    buffer = Data(buffer.dropFirst(offset + count))
    states[chunkStreamID] = state
    guard state.payload.count == state.messageLength else { return .some(nil) }
    return .some(
      RTMPInboundMessage(
        typeID: state.typeID, streamID: state.streamID, timestamp: state.timestamp,
        payload: state.payload))
  }

  private static func uint24(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, data.count >= offset + 3 else { return nil }
    return data[offset..<(offset + 3)].reduce(0) { ($0 << 8) | UInt32($1) }
  }

  private static func uint32(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, data.count >= offset + 4 else { return nil }
    return data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
  }

  private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, data.count >= offset + 4 else { return nil }
    return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
      | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
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
  ) throws -> Data {
    precondition((2...63).contains(chunkStreamID))
    guard payload.count <= 0x00FF_FFFF else {
      throw YouTubeRTMPSError.protocolFailure("message length")
    }
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
