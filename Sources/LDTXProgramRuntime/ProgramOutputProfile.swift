// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

@_exported import LDTXCorelibs
import LDTXMP4

extension ProgramOutputProfile {
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
      targetSegmentDurationSeconds: targetSegmentDurationSeconds,
      startNumber: startNumber
    )
  }
}
