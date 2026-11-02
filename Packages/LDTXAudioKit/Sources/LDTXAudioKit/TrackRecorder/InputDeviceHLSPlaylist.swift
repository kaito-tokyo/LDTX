// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One byte range in an InputDevices fragmented-MP4 resource.
public struct InputDeviceHLSByteRange: Sendable, Equatable {
  public let offset: Int
  public let length: Int

  public init(offset: Int, length: Int) {
    self.offset = offset
    self.length = length
  }
}

/// Timing and byte-range metadata for one InputDevices media segment.
public struct InputDeviceHLSSegment: Sendable, Equatable {
  public let byteRange: InputDeviceHLSByteRange
  public let duration: Double

  public init(byteRange: InputDeviceHLSByteRange, duration: Double) {
    self.byteRange = byteRange
    self.duration = duration
  }
}

/// The retained byte-range index reconstructed from an InputDevices playlist.
public struct InputDeviceHLSPlaylistSnapshot: Sendable, Equatable {
  public let initialization: InputDeviceHLSByteRange
  public let segments: [InputDeviceHLSSegment]
  public let isVOD: Bool

  public init(
    initialization: InputDeviceHLSByteRange,
    segments: [InputDeviceHLSSegment],
    isVOD: Bool
  ) {
    self.initialization = initialization
    self.segments = segments
    self.isVOD = isVOD
  }
}

public enum InputDeviceHLSPlaylistError: Error, LocalizedError {
  case malformed

  public var errorDescription: String? {
    switch self {
    case .malformed:
      "The InputDevices HLS playlist is malformed."
    }
  }
}

/// Writes a retained HLS media playlist for one byte-range fMP4 audio file.
///
/// The playlist is valid as an EVENT playlist while recording. `finish()` makes
/// it a VOD playlist and appends `EXT-X-ENDLIST` after all segment bytes have
/// been committed to the media resource.
public final class InputDeviceHLSPlaylist: @unchecked Sendable {
  private let lock = NSLock()
  private let playlistURL: URL
  private let mediaFileName: String
  private var initialization: InputDeviceHLSByteRange?
  private var segments: [InputDeviceHLSSegment] = []
  private var isFinished = false

  public init(mediaURL: URL, playlistURL: URL) {
    self.playlistURL = playlistURL
    mediaFileName = mediaURL.lastPathComponent
  }

  public func appendInitialization(_ byteRange: InputDeviceHLSByteRange) throws {
    try lock.withLock {
      guard !isFinished else { return }
      initialization = byteRange
      try writeLocked()
    }
  }

  public func append(_ segment: InputDeviceHLSSegment) throws {
    try lock.withLock {
      guard !isFinished else { return }
      segments.append(segment)
      try writeLocked()
    }
  }

  public func finish() throws {
    try lock.withLock {
      guard !isFinished else { return }
      isFinished = true
      try writeLocked()
    }
  }

  public func snapshot() -> (initialization: InputDeviceHLSByteRange?, segments: [InputDeviceHLSSegment], isFinished: Bool) {
    lock.withLock { (initialization, segments, isFinished) }
  }

  /// Reads a retained playlist after its fMP4 resource has been finalized.
  public static func read(from playlistURL: URL) throws -> InputDeviceHLSPlaylistSnapshot {
    let lines = try String(contentsOf: playlistURL, encoding: .utf8)
      .split(whereSeparator: \.isNewline)
      .map(String.init)
    guard lines.first == "#EXTM3U" else {
      throw InputDeviceHLSPlaylistError.malformed
    }

    var initialization: InputDeviceHLSByteRange?
    var pendingDuration: Double?
    var pendingRange: InputDeviceHLSByteRange?
    var segments: [InputDeviceHLSSegment] = []
    var isVOD = false

    for line in lines {
      if line.hasPrefix("#EXT-X-MAP:") {
        guard let range = byteRange(in: line) else {
          throw InputDeviceHLSPlaylistError.malformed
        }
        initialization = range
      } else if line.hasPrefix("#EXTINF:") {
        let value = line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1).first
        guard let value, let duration = Double(value), duration.isFinite, duration > 0 else {
          throw InputDeviceHLSPlaylistError.malformed
        }
        pendingDuration = duration
      } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
        guard let range = byteRange(in: line) else {
          throw InputDeviceHLSPlaylistError.malformed
        }
        pendingRange = range
      } else if line == "#EXT-X-ENDLIST" {
        isVOD = true
      } else if !line.hasPrefix("#") {
        guard let duration = pendingDuration, let range = pendingRange else {
          throw InputDeviceHLSPlaylistError.malformed
        }
        segments.append(.init(byteRange: range, duration: duration))
        pendingDuration = nil
        pendingRange = nil
      }
    }
    guard let initialization, pendingDuration == nil, pendingRange == nil else {
      throw InputDeviceHLSPlaylistError.malformed
    }
    return .init(initialization: initialization, segments: segments, isVOD: isVOD)
  }

  private static func byteRange(in line: String) -> InputDeviceHLSByteRange? {
    let field: Substring
    if let attribute = line.range(of: "BYTERANGE=\"") {
      let remainder = line[attribute.upperBound...]
      guard let end = remainder.firstIndex(of: "\"") else {
        return nil
      }
      field = remainder[..<end]
    } else if let colon = line.firstIndex(of: ":") {
      field = line[line.index(after: colon)...]
    } else {
      return nil
    }
    let values = field.split(separator: "@", maxSplits: 1)
    guard values.count == 2, let length = Int(values[0]), let offset = Int(values[1]), length > 0,
      offset >= 0
    else {
      return nil
    }
    return .init(offset: offset, length: length)
  }

  private func writeLocked() throws {
    var lines = ["#EXTM3U", "#EXT-X-VERSION:6"]
    let longestDuration = segments.map(\.duration).filter { $0.isFinite && $0 > 0 }.max() ?? 1
    lines.append("#EXT-X-TARGETDURATION:\(max(1, Int(ceil(longestDuration))))")
    lines.append("#EXT-X-PLAYLIST-TYPE:\(isFinished ? "VOD" : "EVENT")")
    if let initialization {
      lines.append(
        "#EXT-X-MAP:URI=\"\(mediaFileName)\",BYTERANGE=\"\(initialization.length)@\(initialization.offset)\"")
    }
    for segment in segments {
      lines.append("#EXTINF:\(String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), segment.duration)),")
      lines.append("#EXT-X-BYTERANGE:\(segment.byteRange.length)@\(segment.byteRange.offset)")
      lines.append(mediaFileName)
    }
    if isFinished {
      lines.append("#EXT-X-ENDLIST")
    }
    lines.append("")
    try FileManager.default.createDirectory(
      at: playlistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try lines.joined(separator: "\n").write(to: playlistURL, atomically: true, encoding: .utf8)
  }
}
