// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXMP4

/// The complete contract for an output that can be streamed or recorded by LDTX.
public struct ProgramOutputProfile: Equatable, Sendable {
  public let id: String
  public let width: Int
  public let height: Int
  public let frameRate: Int
  public let videoBitRate: Int
  public let audioSampleRate: Int
  public let audioChannelCount: Int
  public let audioBitRate: Int
  public let segmentDurationSeconds: Int

  public static let sdr1080p60 = Self(
    id: "sdr-1080p60",
    width: 1_920,
    height: 1_080,
    frameRate: 60,
    videoBitRate: 6_000_000,
    audioSampleRate: 48_000,
    audioChannelCount: 2,
    audioBitRate: 128_000,
    segmentDurationSeconds: 2
  )

  public static func sdr1080p60(videoBitRate: Int) -> Self {
    Self(
      id: sdr1080p60.id,
      width: sdr1080p60.width,
      height: sdr1080p60.height,
      frameRate: sdr1080p60.frameRate,
      videoBitRate: videoBitRate,
      audioSampleRate: sdr1080p60.audioSampleRate,
      audioChannelCount: sdr1080p60.audioChannelCount,
      audioBitRate: sdr1080p60.audioBitRate,
      segmentDurationSeconds: sdr1080p60.segmentDurationSeconds)
  }

  public func makeSegmentedMP4Configuration(startNumber: Int = 1) -> SegmentedMP4WriterConfiguration
  {
    SegmentedMP4WriterConfiguration(
      width: width,
      height: height,
      frameRate: frameRate,
      videoBitRate: videoBitRate,
      audioSampleRate: audioSampleRate,
      audioChannelCount: audioChannelCount,
      audioBitRate: audioBitRate,
      segmentDurationSeconds: segmentDurationSeconds,
      startNumber: startNumber
    )
  }
}
