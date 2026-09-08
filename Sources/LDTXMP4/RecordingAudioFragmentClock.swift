// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation

/// Rewrites one audio track's timing without changing encoded media bytes.
/// The caller supplies the source-clock mapping; this type never invents one.
struct RecordingAudioFragmentClock {
  let sourceTimescale: CMTimeScale
  let destinationTimescale: CMTimeScale
  let map: (CMTime) throws -> CMTime
  var trackID: UInt32? = nil

  static func audioTrackID(in data: Data) throws -> UInt32 {
    guard
      let movie = try MP4TimingBox.parse(data).first(where: {
        $0.type == MP4TimingBox.fourCC("moov")
      })
    else {
      throw MP4TimingBoxError.malformed()
    }
    for track in try MP4TimingBox.parse(movie.payload)
    where track.type == MP4TimingBox.fourCC("trak") {
      let children = try MP4TimingBox.parse(track.payload)
      guard let media = children.first(where: { $0.type == MP4TimingBox.fourCC("mdia") }),
        let header = children.first(where: { $0.type == MP4TimingBox.fourCC("tkhd") })
      else { continue }
      let mediaChildren = try MP4TimingBox.parse(media.payload)
      if let handler = mediaChildren.first(where: { $0.type == MP4TimingBox.fourCC("hdlr") }),
        try MP4TimingBox.read(handler.payload, at: 8, bytes: 4)
          == UInt64(MP4TimingBox.fourCC("soun"))
      {
        return UInt32(
          try MP4TimingBox.read(header.payload, at: header.payload.first == 1 ? 20 : 12, bytes: 4))
      }
    }
    throw MP4TimingBoxError.malformed()
  }

  func initialization(_ data: Data) throws -> Data {
    guard sourceTimescale > 0, destinationTimescale > 0 else {
      throw MP4TimingBoxError.integerOverflow
    }
    func rewrite(_ data: Data) throws -> Data {
      try MP4TimingBox.parse(data).reduce(into: Data()) { result, original in
        var box = original
        if box.type == MP4TimingBox.fourCC("trak"), let trackID {
          guard
            let header = try MP4TimingBox.parse(box.payload).first(where: {
              $0.type == MP4TimingBox.fourCC("tkhd")
            })
          else {
            throw MP4TimingBoxError.malformed()
          }
          let id = try MP4TimingBox.read(
            header.payload, at: header.payload.first == 1 ? 20 : 12, bytes: 4)
          if id != UInt64(trackID) {
            result.append(try box.encoded())
            return
          }
        }
        if box.type == MP4TimingBox.fourCC("mdhd") {
          let version = try MP4TimingBox.read(box.payload, at: 0, bytes: 1)
          guard version <= 1 else { throw MP4TimingBoxError.malformed() }
          let offset = version == 0 ? 12 : 20
          guard try MP4TimingBox.read(box.payload, at: offset, bytes: 4) == UInt64(sourceTimescale)
          else {
            throw MP4TimingBoxError.malformed()
          }
          try MP4TimingBox.write(
            UInt64(destinationTimescale), to: &box.payload, at: offset, bytes: 4)
        } else if ["moov", "trak", "mdia"].map(MP4TimingBox.fourCC).contains(box.type) {
          box.payload = try rewrite(box.payload)
        }
        result.append(try box.encoded())
      }
    }
    return try rewrite(data)
  }

  func fragment(_ data: Data) throws -> Data {
    var boxes = try MP4TimingBox.parse(data)
    let indices = boxes.indices.filter { boxes[$0].type == MP4TimingBox.fourCC("moof") }
    guard indices.count == 1, let index = indices.first else {
      throw MP4TimingBoxError.malformed()
    }
    let oldSize = try boxes[index].encoded().count
    var children = try MP4TimingBox.parse(boxes[index].payload)
    let allTracks = children.indices.filter { children[$0].type == MP4TimingBox.fourCC("traf") }
    let tracks = try allTracks.filter { index in
      guard let trackID else { return true }
      guard
        let header = try MP4TimingBox.parse(children[index].payload).first(where: {
          $0.type == MP4TimingBox.fourCC("tfhd")
        })
      else {
        throw MP4TimingBoxError.malformed()
      }
      return try MP4TimingBox.read(header.payload, at: 4, bytes: 4) == UInt64(trackID)
    }
    if trackID != nil && tracks.isEmpty { return data }
    guard tracks.count == 1, let track = tracks.first else {
      throw MP4TimingBoxError.malformed()
    }
    var fields = try MP4TimingBox.parse(children[track].payload)
    guard let header = fields.first(where: { $0.type == MP4TimingBox.fourCC("tfhd") }),
      let decodeIndex = fields.firstIndex(where: { $0.type == MP4TimingBox.fourCC("tfdt") })
    else { throw MP4TimingBoxError.malformed() }
    let headerFlags = try MP4TimingBox.read(header.payload, at: 0, bytes: 4) & 0xffffff
    guard headerFlags & 0x20000 != 0, headerFlags & 1 == 0 else {
      throw MP4TimingBoxError.malformed()
    }
    let defaultOffset = 8 + (headerFlags & 2 != 0 ? 4 : 0)
    let defaultDuration =
      headerFlags & 8 != 0
      ? try MP4TimingBox.read(header.payload, at: defaultOffset, bytes: 4) : 0
    let version = try MP4TimingBox.read(fields[decodeIndex].payload, at: 0, bytes: 1)
    guard version <= 1 else { throw MP4TimingBoxError.malformed() }
    var tick = try MP4TimingBox.read(
      fields[decodeIndex].payload, at: 4, bytes: version == 1 ? 8 : 4)
    var decode = Data(repeating: 0, count: 12)
    decode[0] = 1
    try MP4TimingBox.write(try mapped(tick), to: &decode, at: 4, bytes: 8)
    fields[decodeIndex].payload = decode
    for fieldIndex in fields.indices where fields[fieldIndex].type == MP4TimingBox.fourCC("trun") {
      let input = fields[fieldIndex].payload
      let flags = try MP4TimingBox.read(input, at: 0, bytes: 4)
      guard flags & 0x800 == 0, flags & 1 != 0 else {
        throw MP4TimingBoxError.malformed()
      }
      let count = try MP4TimingBox.read(input, at: 4, bytes: 4)
      let stride = [UInt64(0x100), 0x200, 0x400].filter { flags & $0 != 0 }.count * 4
      let prefix = 12 + (flags & 4 != 0 ? 4 : 0)
      guard input.count >= prefix, count <= 1_000_000,
        stride == 0 || count <= UInt64((input.count - prefix) / stride)
      else { throw MP4TimingBoxError.malformed() }
      var output = Data(input.prefix(prefix))
      try MP4TimingBox.write(flags | 0x100, to: &output, at: 0, bytes: 4)
      var cursor = prefix
      for _ in 0..<count {
        let duration =
          flags & 0x100 != 0
          ? try MP4TimingBox.read(input, at: cursor, bytes: 4) : defaultDuration
        if flags & 0x100 != 0 { cursor += 4 }
        guard duration > 0, tick <= UInt64(Int64.max) - duration else {
          throw MP4TimingBoxError.integerOverflow
        }
        let start = try mapped(tick)
        let end = try mapped(tick + duration)
        guard end > start else { throw MP4TimingBoxError.malformed() }
        var encodedDuration = Data(repeating: 0, count: 4)
        try MP4TimingBox.write(end - start, to: &encodedDuration, at: 0, bytes: 4)
        output.append(encodedDuration)
        for flag: UInt64 in [0x200, 0x400] where flags & flag != 0 {
          output.append(input[cursor..<(cursor + 4)])
          cursor += 4
        }
        tick += duration
      }
      guard cursor == input.count else { throw MP4TimingBoxError.malformed() }
      fields[fieldIndex].payload = output
    }
    func encoded(_ boxes: [MP4TimingBox]) throws -> Data {
      try boxes.reduce(into: Data()) { try $0.append($1.encoded()) }
    }
    children[track].payload = try encoded(fields)
    boxes[index].payload = try encoded(children)
    let delta = try boxes[index].encoded().count - oldSize
    for childIndex in allTracks {
      var adjustedFields = try MP4TimingBox.parse(children[childIndex].payload)
      for fieldIndex in adjustedFields.indices
      where adjustedFields[fieldIndex].type == MP4TimingBox.fourCC("trun") {
        guard try MP4TimingBox.read(adjustedFields[fieldIndex].payload, at: 0, bytes: 4) & 1 != 0
        else {
          throw MP4TimingBoxError.malformed()
        }
        let offset = try MP4TimingBox.read(adjustedFields[fieldIndex].payload, at: 8, bytes: 4)
        let adjusted = Int64(Int32(bitPattern: UInt32(offset))) + Int64(delta)
        guard adjusted >= 0, adjusted <= Int64(Int32.max) else {
          throw MP4TimingBoxError.integerOverflow
        }
        try MP4TimingBox.write(
          UInt64(adjusted), to: &adjustedFields[fieldIndex].payload, at: 8, bytes: 4)
      }
      children[childIndex].payload = try encoded(adjustedFields)
    }
    boxes[index].payload = try encoded(children)
    return try encoded(boxes)
  }

  private func mapped(_ tick: UInt64) throws -> UInt64 {
    guard tick <= UInt64(Int64.max), sourceTimescale > 0, destinationTimescale > 0 else {
      throw MP4TimingBoxError.integerOverflow
    }
    let result = CMTimeConvertScale(
      try map(CMTime(value: Int64(tick), timescale: sourceTimescale)),
      timescale: destinationTimescale, method: .roundHalfAwayFromZero)
    guard result.isNumeric, result.value >= 0 else { throw MP4TimingBoxError.malformed() }
    return UInt64(result.value)
  }
}
