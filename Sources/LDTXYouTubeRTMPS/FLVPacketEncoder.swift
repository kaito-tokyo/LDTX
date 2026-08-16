// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct FLVPacket: Equatable, Sendable {
  var typeID: UInt8
  var timestamp: UInt32
  var payload: Data
}

enum FLVPacketEncoder {
  static func avcSequenceHeader(_ format: YouTubeRTMPSVideoFormat) throws -> FLVPacket {
    let sps = Data(format.sequenceParameterSet)
    let pps = Data(format.pictureParameterSet)
    guard sps.count >= 4, !pps.isEmpty, format.nalUnitHeaderLength == 4,
      sps.count <= Int(UInt16.max), pps.count <= Int(UInt16.max)
    else { throw YouTubeRTMPSError.invalidVideoFormat }
    var payload = Data([0x17, 0, 0, 0, 0, 1, sps[1], sps[2], sps[3], 0xFF, 0xE1])
    payload.appendUInt16(UInt16(sps.count))
    payload.append(sps)
    payload.append(1)
    payload.appendUInt16(UInt16(pps.count))
    payload.append(pps)
    return FLVPacket(typeID: 9, timestamp: 0, payload: payload)
  }

  static func video(_ sample: YouTubeRTMPSVideoSample) throws -> FLVPacket {
    let timestamp = try rtmpTimestamp(sample.decodeTime.milliseconds)
    let (composition, overflow) = sample.presentationTime.milliseconds.subtractingReportingOverflow(
      sample.decodeTime.milliseconds)
    guard !overflow, composition >= -8_388_608, composition <= 8_388_607,
      !sample.avccData.isEmpty
    else {
      throw YouTubeRTMPSError.invalidTimestamp
    }
    let value = UInt32(bitPattern: Int32(composition)) & 0x00FF_FFFF
    var payload = Data([sample.isKeyFrame ? 0x17 : 0x27, 1])
    payload.appendUInt24(value)
    payload.append(sample.avccData)
    return FLVPacket(typeID: 9, timestamp: timestamp, payload: payload)
  }

  static func aacSequenceHeader(_ format: YouTubeRTMPSAudioFormat) throws -> FLVPacket {
    guard !format.audioSpecificConfig.isEmpty else {
      throw YouTubeRTMPSError.protocolFailure("AAC format")
    }
    return FLVPacket(
      typeID: 8,
      timestamp: 0,
      payload: Data([0xAF, 0]) + format.audioSpecificConfig
    )
  }

  static func audio(_ sample: YouTubeRTMPSAudioSample) throws -> FLVPacket {
    FLVPacket(
      typeID: 8,
      timestamp: try rtmpTimestamp(sample.presentationTime.milliseconds),
      payload: Data([0xAF, 1]) + sample.rawAACData)
  }

  private static func rtmpTimestamp(_ value: Int64) throws -> UInt32 {
    guard value >= 0 else { throw YouTubeRTMPSError.invalidTimestamp }
    return UInt32(truncatingIfNeeded: value)
  }
}

extension Data {
  mutating func appendUInt16(_ value: UInt16) {
    append(UInt8(truncatingIfNeeded: value >> 8))
    append(UInt8(truncatingIfNeeded: value))
  }

  mutating func appendUInt24(_ value: UInt32) {
    append(UInt8(truncatingIfNeeded: value >> 16))
    append(UInt8(truncatingIfNeeded: value >> 8))
    append(UInt8(truncatingIfNeeded: value))
  }

  mutating func appendUInt32(_ value: UInt32) {
    append(UInt8(truncatingIfNeeded: value >> 24))
    append(UInt8(truncatingIfNeeded: value >> 16))
    append(UInt8(truncatingIfNeeded: value >> 8))
    append(UInt8(truncatingIfNeeded: value))
  }

  mutating func appendLittleEndianUInt32(_ value: UInt32) {
    append(UInt8(truncatingIfNeeded: value))
    append(UInt8(truncatingIfNeeded: value >> 8))
    append(UInt8(truncatingIfNeeded: value >> 16))
    append(UInt8(truncatingIfNeeded: value >> 24))
  }
}
