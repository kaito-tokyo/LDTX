// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Shared encoding settings for the production segmented MP4 writers.
///
/// This configuration remains independent of the retired `SegmentedMP4Writer`
/// implementation because the H.264 passthrough, PCM audio, and muxed writers
/// use the same output contract.
public struct SegmentedMP4WriterConfiguration: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: Int
    public var videoBitRate: Int
    public var videoPixelBufferPoolMinimumBufferCount: Int
    public var audioSampleRate: Int
    public var audioChannelCount: Int
    public var audioBitRate: Int
    public var targetSegmentDurationSeconds: Int
    public var timescale: Int
    public var startNumber: Int

    public init(
        width: Int,
        height: Int,
        frameRate: Int,
        videoBitRate: Int,
        videoPixelBufferPoolMinimumBufferCount: Int = 24,
        audioSampleRate: Int = 48_000,
        audioChannelCount: Int = 2,
        audioBitRate: Int = 128_000,
        targetSegmentDurationSeconds: Int = 2,
        timescale: Int = 1_000,
        startNumber: Int = 1
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.videoBitRate = videoBitRate
        self.videoPixelBufferPoolMinimumBufferCount = videoPixelBufferPoolMinimumBufferCount
        self.audioSampleRate = audioSampleRate
        self.audioChannelCount = audioChannelCount
        self.audioBitRate = audioBitRate
        self.targetSegmentDurationSeconds = targetSegmentDurationSeconds
        self.timescale = timescale
        self.startNumber = startNumber
    }
}
