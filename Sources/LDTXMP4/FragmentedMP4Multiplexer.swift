// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Combines the single-track fragments emitted by two AVAssetWriter instances.
///
/// Video keeps track ID 1. Audio is rewritten to track ID 2. The inputs must use
/// a single `moov` initialization segment and one `moof`/`mdat` pair per media
/// segment, which is the shape produced by the segmented writers in this module.
public enum FragmentedMP4Multiplexer {
  public static func validateMatchingMediaSegmentNumbers(
    video: Set<Int>, audio: Set<Int>
  ) throws {
    let unmatchedVideo = video.subtracting(audio).sorted()
    let unmatchedAudio = audio.subtracting(video).sorted()
    guard unmatchedVideo.isEmpty, unmatchedAudio.isEmpty else {
      throw FragmentedMP4MultiplexerError.unmatchedMediaSegments(
        video: unmatchedVideo, audio: unmatchedAudio)
    }
  }

  public static func initialization(video: Data, audio: Data) throws -> Data {
    let videoBoxes = try MP4Box.parseAll(video)
    let audioBoxes = try MP4Box.parseAll(audio)
    guard let videoMovie = videoBoxes.first(where: { $0.type == "moov" }),
      let audioMovie = audioBoxes.first(where: { $0.type == "moov" })
    else {
      throw FragmentedMP4MultiplexerError.missingBox("moov")
    }

    var videoChildren = try MP4Box.parseAll(videoMovie.payload)
    let audioChildren = try MP4Box.parseAll(audioMovie.payload)
    guard var audioTrack = audioChildren.first(where: { $0.type == "trak" }),
      let audioMovieExtends = audioChildren.first(where: { $0.type == "mvex" })
    else {
      throw FragmentedMP4MultiplexerError.invalidInitialization
    }
    audioTrack = try rewriteTrackID(in: audioTrack, boxType: "tkhd", trackID: 2)

    let audioExtendsChildren = try MP4Box.parseAll(audioMovieExtends.payload)
    guard var audioTrackExtends = audioExtendsChildren.first(where: { $0.type == "trex" }) else {
      throw FragmentedMP4MultiplexerError.invalidInitialization
    }
    try audioTrackExtends.payload.writeUInt32(2, at: 4)

    guard let movieExtendsIndex = videoChildren.firstIndex(where: { $0.type == "mvex" }) else {
      throw FragmentedMP4MultiplexerError.invalidInitialization
    }
    var movieExtendsChildren = try MP4Box.parseAll(videoChildren[movieExtendsIndex].payload)
    movieExtendsChildren.append(audioTrackExtends)
    videoChildren[movieExtendsIndex].payload = MP4Box.serialize(movieExtendsChildren)
    videoChildren.append(audioTrack)

    if let movieHeaderIndex = videoChildren.firstIndex(where: { $0.type == "mvhd" }) {
      var movieHeader = videoChildren[movieHeaderIndex]
      guard movieHeader.payload.count >= 4 else {
        throw FragmentedMP4MultiplexerError.invalidInitialization
      }
      try movieHeader.payload.writeUInt32(3, at: movieHeader.payload.count - 4)
      videoChildren[movieHeaderIndex] = movieHeader
    }

    let mergedMovie = MP4Box(type: "moov", payload: MP4Box.serialize(videoChildren))
    var result = Data()
    for box in videoBoxes where box.type != "moov" {
      result.append(box.serialized)
    }
    result.append(mergedMovie.serialized)
    return result
  }

  public static func media(video: Data, audio: Data) throws -> Data {
    let videoBoxes = try MP4Box.parseAll(video)
    let audioBoxes = try MP4Box.parseAll(audio)
    guard let videoFragment = videoBoxes.first(where: { $0.type == "moof" }),
      let videoMediaData = videoBoxes.first(where: { $0.type == "mdat" }),
      let audioFragment = audioBoxes.first(where: { $0.type == "moof" }),
      let audioMediaData = audioBoxes.first(where: { $0.type == "mdat" })
    else {
      throw FragmentedMP4MultiplexerError.invalidMediaSegment
    }

    var videoFragmentChildren = try MP4Box.parseAll(videoFragment.payload)
    let audioFragmentChildren = try MP4Box.parseAll(audioFragment.payload)
    guard var audioTrackFragment = audioFragmentChildren.first(where: { $0.type == "traf" }) else {
      throw FragmentedMP4MultiplexerError.invalidMediaSegment
    }
    audioTrackFragment = try rewriteTrackID(
      in: audioTrackFragment, boxType: "tfhd", trackID: 2)
    videoFragmentChildren.append(audioTrackFragment)

    // Box size does not change while data offsets are patched.
    let preliminaryFragment = MP4Box(
      type: "moof", payload: MP4Box.serialize(videoFragmentChildren))
    let mediaDataHeaderSize = 8
    let videoOffset = preliminaryFragment.serialized.count + mediaDataHeaderSize
    let audioOffset = videoOffset + videoMediaData.payload.count

    guard let videoTrackIndex = videoFragmentChildren.firstIndex(where: { $0.type == "traf" }),
      let audioTrackIndex = videoFragmentChildren.lastIndex(where: { $0.type == "traf" })
    else {
      throw FragmentedMP4MultiplexerError.invalidMediaSegment
    }
    videoFragmentChildren[videoTrackIndex] = try rebaseDataOffsets(
      in: videoFragmentChildren[videoTrackIndex], firstOffset: videoOffset)
    videoFragmentChildren[audioTrackIndex] = try rebaseDataOffsets(
      in: videoFragmentChildren[audioTrackIndex], firstOffset: audioOffset)

    let mergedFragment = MP4Box(
      type: "moof", payload: MP4Box.serialize(videoFragmentChildren))
    var mediaPayload = videoMediaData.payload
    mediaPayload.append(audioMediaData.payload)
    let mergedMediaData = MP4Box(type: "mdat", payload: mediaPayload)

    var result = Data()
    for box in videoBoxes where box.type != "moof" && box.type != "mdat" {
      result.append(box.serialized)
    }
    result.append(mergedFragment.serialized)
    result.append(mergedMediaData.serialized)
    return result
  }

  private static func rewriteTrackID(
    in container: MP4Box, boxType: String, trackID: UInt32
  ) throws -> MP4Box {
    var result = container
    var children = try MP4Box.parseAll(result.payload)
    guard let index = children.firstIndex(where: { $0.type == boxType }) else {
      throw FragmentedMP4MultiplexerError.missingBox(boxType)
    }
    var header = children[index]
    let version = try header.payload.uint8(at: 0)
    let offset: Int
    switch boxType {
    case "tkhd": offset = version == 1 ? 20 : 12
    case "tfhd": offset = 4
    default: throw FragmentedMP4MultiplexerError.unsupportedBox(boxType)
    }
    try header.payload.writeUInt32(trackID, at: offset)
    children[index] = header
    result.payload = MP4Box.serialize(children)
    return result
  }

  private static func rebaseDataOffsets(
    in trackFragment: MP4Box,
    firstOffset: Int
  ) throws -> MP4Box {
    guard firstOffset <= Int(Int32.max) else {
      throw FragmentedMP4MultiplexerError.segmentTooLarge
    }
    var result = trackFragment
    var children = try MP4Box.parseAll(result.payload)
    let runIndices = children.indices.filter { children[$0].type == "trun" }
    guard let firstRunIndex = runIndices.first else {
      throw FragmentedMP4MultiplexerError.missingBox("trun")
    }
    guard let originalFirstOffset = try explicitDataOffset(in: children[firstRunIndex]) else {
      // DASH-IF uses an explicit trun data offset to anchor each track fragment.
      throw FragmentedMP4MultiplexerError.missingDataOffset
    }
    let delta = Int64(firstOffset) - Int64(originalFirstOffset)
    for index in runIndices {
      var run = children[index]
      // ISO/IEC 14496-12 permits a later run to omit data_offset. Such a run
      // remains contiguous with the preceding run, so moving the complete mdat
      // payload preserves its implicit location without patching the trun.
      guard let originalOffset = try explicitDataOffset(in: run) else { continue }
      let rebasedOffset = Int64(originalOffset) + delta
      guard rebasedOffset >= Int64(Int32.min), rebasedOffset <= Int64(Int32.max) else {
        throw FragmentedMP4MultiplexerError.segmentTooLarge
      }
      try run.payload.writeUInt32(UInt32(bitPattern: Int32(rebasedOffset)), at: 8)
      children[index] = run
    }
    result.payload = MP4Box.serialize(children)
    return result
  }

  private static func explicitDataOffset(in run: MP4Box) throws -> Int32? {
    guard run.payload.count >= 8 else {
      throw FragmentedMP4MultiplexerError.invalidMediaSegment
    }
    let flags = try run.payload.uint32(at: 0) & 0x00FF_FFFF
    guard flags & 0x000001 != 0 else { return nil }
    guard run.payload.count >= 12 else {
      throw FragmentedMP4MultiplexerError.invalidMediaSegment
    }
    return Int32(bitPattern: try run.payload.uint32(at: 8))
  }
}

public enum FragmentedMP4MultiplexerError: Error, LocalizedError {
  case missingBox(String)
  case unsupportedBox(String)
  case invalidInitialization
  case invalidMediaSegment
  case invalidBox
  case missingDataOffset
  case segmentTooLarge
  case unmatchedMediaSegments(video: [Int], audio: [Int])

  public var errorDescription: String? {
    switch self {
    case .missingBox(let type): "The fragmented MP4 is missing its \(type) box."
    case .unsupportedBox(let type): "The fragmented MP4 box \(type) is unsupported."
    case .invalidInitialization: "The fragmented MP4 initialization segment is invalid."
    case .invalidMediaSegment: "The fragmented MP4 media segment is invalid."
    case .invalidBox: "The fragmented MP4 contains an invalid box."
    case .missingDataOffset: "The fragmented MP4 track run has no data offset."
    case .segmentTooLarge: "The fragmented MP4 media segment is too large."
    case .unmatchedMediaSegments(let video, let audio):
      "The fragmented MP4 has unmatched media segments (video: \(video), audio: \(audio))."
    }
  }
}

private struct MP4Box {
  var type: String
  var payload: Data

  var serialized: Data {
    var result = Data()
    result.appendUInt32(UInt32(payload.count + 8))
    result.append(type.data(using: .ascii)!)
    result.append(payload)
    return result
  }

  static func parseAll(_ data: Data) throws -> [MP4Box] {
    var boxes: [MP4Box] = []
    var offset = 0
    while offset < data.count {
      guard data.count - offset >= 8 else { throw FragmentedMP4MultiplexerError.invalidBox }
      let shortSize = try data.uint32(at: offset)
      guard let type = String(data: data[(offset + 4)..<(offset + 8)], encoding: .ascii) else {
        throw FragmentedMP4MultiplexerError.invalidBox
      }
      let headerSize: Int
      let size: Int
      if shortSize == 1 {
        guard data.count - offset >= 16 else { throw FragmentedMP4MultiplexerError.invalidBox }
        let longSize = try data.uint64(at: offset + 8)
        guard longSize <= UInt64(Int.max) else {
          throw FragmentedMP4MultiplexerError.segmentTooLarge
        }
        headerSize = 16
        size = Int(longSize)
      } else if shortSize == 0 {
        headerSize = 8
        size = data.count - offset
      } else {
        headerSize = 8
        size = Int(shortSize)
      }
      guard size >= headerSize, offset + size <= data.count else {
        throw FragmentedMP4MultiplexerError.invalidBox
      }
      boxes.append(
        MP4Box(type: type, payload: Data(data[(offset + headerSize)..<(offset + size)])))
      offset += size
    }
    return boxes
  }

  static func serialize(_ boxes: [MP4Box]) -> Data {
    boxes.reduce(into: Data()) { $0.append($1.serialized) }
  }
}

extension Data {
  fileprivate mutating func appendUInt32(_ value: UInt32) {
    var value = value.bigEndian
    Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
  }

  fileprivate func uint8(at offset: Int) throws -> UInt8 {
    guard indices.contains(offset) else { throw FragmentedMP4MultiplexerError.invalidBox }
    return self[index(startIndex, offsetBy: offset)]
  }

  fileprivate func uint32(at offset: Int) throws -> UInt32 {
    guard offset >= 0, count - offset >= 4 else {
      throw FragmentedMP4MultiplexerError.invalidBox
    }
    return self[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  }

  fileprivate func uint64(at offset: Int) throws -> UInt64 {
    guard offset >= 0, count - offset >= 8 else {
      throw FragmentedMP4MultiplexerError.invalidBox
    }
    return self[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
  }

  fileprivate mutating func writeUInt32(_ value: UInt32, at offset: Int) throws {
    guard offset >= 0, count - offset >= 4 else {
      throw FragmentedMP4MultiplexerError.invalidBox
    }
    replaceSubrange(
      offset..<(offset + 4),
      with: [
        UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
      ])
  }
}
