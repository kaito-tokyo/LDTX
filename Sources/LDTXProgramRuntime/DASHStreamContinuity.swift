// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDash
import LDTXMP4
import LDTXYouTubeOutputProtocol

struct DASHStreamOutputConfigurationFingerprint: Equatable, Sendable {
  var profileID: String
  var width: Int
  var height: Int
  var frameRate: Int
  var videoBitRate: Int
  var videoPixelBufferPoolMinimumBufferCount: Int
  var audioSampleRate: Int
  var audioChannelCount: Int
  var audioBitRate: Int
  var targetSegmentDurationSeconds: Int
  var timescale: Int
  var audioTrackIDs: [String]

  var outputServiceValue: String {
    [
      "v2", profileID, String(width), String(height), String(frameRate), String(videoBitRate),
      String(videoPixelBufferPoolMinimumBufferCount), String(audioSampleRate),
      String(audioChannelCount), String(audioBitRate), String(targetSegmentDurationSeconds),
      String(timescale), audioTrackIDs.joined(separator: ","),
    ].joined(separator: ":")
  }

  init(
    writerConfiguration: SegmentedMP4WriterConfiguration,
    audioTrackIDs: [String],
    profileID: String = ProgramOutputProfile.sdr1080p60.id
  ) {
    self.profileID = profileID
    width = writerConfiguration.width
    height = writerConfiguration.height
    frameRate = writerConfiguration.frameRate
    videoBitRate = writerConfiguration.videoBitRate
    videoPixelBufferPoolMinimumBufferCount =
      writerConfiguration.videoPixelBufferPoolMinimumBufferCount
    audioSampleRate = writerConfiguration.audioSampleRate
    audioChannelCount = writerConfiguration.audioChannelCount
    audioBitRate = writerConfiguration.audioBitRate
    targetSegmentDurationSeconds = writerConfiguration.targetSegmentDurationSeconds
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
