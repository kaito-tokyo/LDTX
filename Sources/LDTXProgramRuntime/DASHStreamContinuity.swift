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
    return true
  }
}

struct RecordingSplitState: Sendable {
  var baseDirectory: URL
  var recordID: String
  var nextPartIndex: Int
  var packageConfiguration: HLSByteRangeRecordingPackageConfiguration

  var initialDirectory: URL {
    Self.directoryURL(baseDirectory: baseDirectory, recordID: recordID, partIndex: 1)
  }

  mutating func nextDirectory() -> URL {
    let partIndex = nextPartIndex
    nextPartIndex += 1
    return Self.directoryURL(baseDirectory: baseDirectory, recordID: recordID, partIndex: partIndex)
  }

  static func directoryURL(
    baseDirectory: URL,
    recordID: String,
    partIndex: Int
  ) -> URL {
    let stem: String
    if partIndex <= 1 {
      stem = recordID
    } else {
      stem = "\(recordID)-part\(String(format: "%04d", partIndex))"
    }
    return
      baseDirectory
      .appendingPathComponent(stem, isDirectory: true)
      .appendingPathExtension("ldtxrecord")
  }
}
