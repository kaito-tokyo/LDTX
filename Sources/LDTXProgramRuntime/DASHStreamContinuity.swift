// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDash
import LDTXMP4
import LDTXYouTubeOutputProtocol

struct DASHStreamOutputConfigurationFingerprint: Equatable, Sendable {
  var width: Int
  var height: Int
  var frameRate: Int
  var videoBitRate: Int
  var videoPixelBufferPoolMinimumBufferCount: Int
  var audioSampleRate: Int
  var audioChannelCount: Int
  var audioBitRate: Int
  var segmentDurationSeconds: Int
  var timescale: Int
  var audioTrackIDs: [String]

  var outputServiceValue: String {
    [
      "v1", String(width), String(height), String(frameRate), String(videoBitRate),
      String(videoPixelBufferPoolMinimumBufferCount), String(audioSampleRate),
      String(audioChannelCount), String(audioBitRate), String(segmentDurationSeconds),
      String(timescale), audioTrackIDs.joined(separator: ","),
    ].joined(separator: ":")
  }

  init(
    writerConfiguration: SegmentedMP4WriterConfiguration,
    audioTrackIDs: [String]
  ) {
    width = writerConfiguration.width
    height = writerConfiguration.height
    frameRate = writerConfiguration.frameRate
    videoBitRate = writerConfiguration.videoBitRate
    videoPixelBufferPoolMinimumBufferCount =
      writerConfiguration.videoPixelBufferPoolMinimumBufferCount
    audioSampleRate = writerConfiguration.audioSampleRate
    audioChannelCount = writerConfiguration.audioChannelCount
    audioBitRate = writerConfiguration.audioBitRate
    segmentDurationSeconds = writerConfiguration.segmentDurationSeconds
    timescale = writerConfiguration.timescale
    self.audioTrackIDs = audioTrackIDs.sorted()
  }
}

struct DASHStreamContinuityState: Equatable, Sendable {
  var endpointIdentity: String?
  var availabilityStartTime: Date
  var nextMediaSegmentNumber: Int
  var latestInitSegment: Data?
  var latestAudioInitSegments: [String: Data]
  var outputConfigurationFingerprint: DASHStreamOutputConfigurationFingerprint
  var nextMediaTimeSeconds: Double? = nil

  func canResume(
    endpoint: DASHIngestEndpoint,
    outputConfigurationFingerprint: DASHStreamOutputConfigurationFingerprint
  ) -> Bool {
    endpointIdentity == endpoint.baseURL.absoluteString
      && self.outputConfigurationFingerprint == outputConfigurationFingerprint
  }

  mutating func noteMainSegment(_ segment: SegmentedMP4Segment) {
    switch segment.kind {
    case .initialization:
      latestInitSegment = segment.data
    case .media(let number):
      nextMediaSegmentNumber = max(nextMediaSegmentNumber, number + 1)
    }
  }

  @discardableResult
  mutating func apply(_ checkpoint: YouTubeOutputCheckpoint) -> Bool {
    guard outputConfigurationFingerprint.outputServiceValue == checkpoint.configurationFingerprint
    else { return false }
    nextMediaSegmentNumber = checkpoint.nextMediaSegmentNumber
    latestInitSegment = checkpoint.initializationSegment
    availabilityStartTime = checkpoint.availabilityStartTime
    nextMediaTimeSeconds = checkpoint.nextMediaTimeSeconds
    return true
  }
}
