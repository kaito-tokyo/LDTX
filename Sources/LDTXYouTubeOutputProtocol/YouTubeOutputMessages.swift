// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXOutputMedia

/// Compatibility names for the output-service wire API.  Their concrete
/// contract is output-neutral so Main Recording and YouTube share it exactly.
public typealias YouTubeOutputMediaTime = ProgramOutputMediaTime
public typealias YouTubeOutputH264Format = ProgramOutputH264Format
public typealias YouTubeOutputH264AccessUnit = ProgramOutputH264AccessUnit
public typealias YouTubeOutputAACFormat = ProgramOutputAACFormat
public typealias YouTubeOutputAACAccessUnit = ProgramOutputAACAccessUnit

public struct YouTubeOutputMediaBatch: Equatable, Sendable {
  public var protocolVersion: UInt32
  public var context: YouTubeOutputContext
  public var sequence: UInt64
  public var videoFormat: YouTubeOutputH264Format?
  public var video: [YouTubeOutputH264AccessUnit]
  public var audioFormat: YouTubeOutputAACFormat?
  public var audio: [YouTubeOutputAACAccessUnit]

  public init(
    context: YouTubeOutputContext,
    sequence: UInt64,
    videoFormat: YouTubeOutputH264Format? = nil,
    video: [YouTubeOutputH264AccessUnit] = [],
    audioFormat: YouTubeOutputAACFormat? = nil,
    audio: [YouTubeOutputAACAccessUnit] = []
  ) {
    protocolVersion = LDTXYouTubeOutputServiceProcessInterfaces.protocolVersion
    self.context = context
    self.sequence = sequence
    self.videoFormat = videoFormat
    self.audioFormat = audioFormat
    self.video = video
    self.audio = audio
  }
}

public enum YouTubeOutputMessageError: Error, LocalizedError {
  case invalidSessionID(String)
  case invalidURL(String)

  public var errorDescription: String? {
    switch self {
    case .invalidSessionID(let value): "Invalid output session ID: \(value)"
    case .invalidURL(let value): "Invalid output endpoint URL: \(value)"
    }
  }
}
