// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import CoreMedia
import Foundation
import LDTXMP4
import LDTXYouTubeOutputProtocol

final class YouTubeOutputMediaProcessor: @unchecked Sendable {
  typealias SegmentHandler = @Sendable (Result<SegmentedMP4Segment, any Error>) -> Void

  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.youtube-output-service.media")
  private let segmentDurationSeconds: Int
  private let startNumber: Int
  private let onSegment: SegmentHandler
  private var videoWriter: H264PassthroughSegmentedMP4Writer?
  private var audioWriter: PCMAudioSegmentedMP4Writer?
  private var videoInitialization: Data?
  private var audioInitialization: Data?
  private var videoSegments: [Int: SegmentedMP4Segment] = [:]
  private var audioSegments: [Int: SegmentedMP4Segment] = [:]
  private var videoFormat: CMVideoFormatDescription?
  private var pendingVideoFormat: CMVideoFormatDescription?
  private var videoFrameHold = YouTubeOutputVideoFrameHold()
  private var mediaTimeline: YouTubeOutputMediaTimeline

  init(
    segmentDurationSeconds: Int,
    startNumber: Int,
    outputOffset: YouTubeOutputMediaTime = YouTubeOutputMediaTime(value: 1, timescale: 1),
    onSegment: @escaping SegmentHandler
  ) {
    self.segmentDurationSeconds = segmentDurationSeconds
    self.startNumber = startNumber
    mediaTimeline = YouTubeOutputMediaTimeline(outputOffset: outputOffset)
    self.onSegment = onSegment
  }

  func append(_ batch: YouTubeOutputMediaBatch) throws {
    if let format = batch.videoFormat {
      videoFormat = try Self.makeVideoFormat(format)
    }
    establishMediaTimelineIfNeeded(from: batch.video)
    for var accessUnit in batch.video {
      // Start the live stream at the chosen keyframe; do not retain partial units.
      guard mediaTimeline.startsAtOrAfterOrigin(accessUnit.presentationTime) else { continue }
      guard let videoFormat else { throw YouTubeOutputMediaProcessorError.missingVideoFormat }
      guard let presentationTime = mediaTimeline.translate(accessUnit.presentationTime) else {
        throw YouTubeOutputMediaProcessorError.invalidVideoSample
      }
      accessUnit.presentationTime = presentationTime
      if let decodeTime = accessUnit.decodeTime {
        guard let translatedDecodeTime = mediaTimeline.translate(decodeTime) else {
          throw YouTubeOutputMediaProcessorError.invalidVideoSample
        }
        accessUnit.decodeTime = translatedDecodeTime
      }
      if let ready = videoFrameHold.append(accessUnit) {
        guard let pendingVideoFormat else {
          throw YouTubeOutputMediaProcessorError.missingVideoFormat
        }
        try appendVideo(ready, format: pendingVideoFormat)
      }
      pendingVideoFormat = videoFormat
    }
    for var buffer in batch.audio {
      // Audio buffers crossing the origin are intentionally discarded as whole units.
      guard mediaTimeline.startsAtOrAfterOrigin(buffer.presentationTime) else { continue }
      guard let presentationTime = mediaTimeline.translate(buffer.presentationTime) else {
        throw YouTubeOutputMediaProcessorError.invalidAudio
      }
      buffer.presentationTime = presentationTime
      let sample = try Self.makeAudioSample(buffer)
      if audioWriter == nil {
        guard let format = sample.formatDescription else {
          throw YouTubeOutputMediaProcessorError.invalidAudio
        }
        audioWriter = try PCMAudioSegmentedMP4Writer(
          formatDescription: format,
          segmentDurationSeconds: segmentDurationSeconds,
          startNumber: startNumber,
          onFailure: { [weak self] error in self?.onSegment(.failure(error)) }
        ) { [weak self] segment in
          self?.receiveAudio(segment)
        }
      }
      audioWriter?.append(sample)
    }
  }

  private func establishMediaTimelineIfNeeded(from accessUnits: [YouTubeOutputH264AccessUnit]) {
    guard mediaTimeline.origin == nil else { return }
    guard
      let keyFrame = accessUnits.first(where: {
        $0.isKeyFrame && $0.presentationTime.timescale > 0
      })
    else { return }
    mediaTimeline.establishOrigin(at: keyFrame.presentationTime)
  }

  func finish(completion: @escaping @Sendable (Result<Void, any Error>) -> Void) {
    do {
      if let final = videoFrameHold.finish() {
        guard let pendingVideoFormat else {
          throw YouTubeOutputMediaProcessorError.missingVideoFormat
        }
        try appendVideo(final, format: pendingVideoFormat)
      }
    } catch {
      completion(.failure(error))
      return
    }
    let group = DispatchGroup()
    let result = LockedFinishResult()
    if let videoWriter {
      group.enter()
      videoWriter.finish {
        result.record($0)
        group.leave()
      }
    }
    if let audioWriter {
      group.enter()
      audioWriter.finish {
        result.record($0)
        group.leave()
      }
    }
    group.notify(queue: queue) { [self] in
      guard case .success = result.value else {
        completion(result.value)
        return
      }
      emitAvailableSegments()
      do {
        try FragmentedMP4Multiplexer.validateMatchingMediaSegmentNumbers(
          video: Set(videoSegments.keys), audio: Set(audioSegments.keys))
        completion(.success(()))
      } catch {
        completion(.failure(error))
      }
    }
  }

  private func appendVideo(
    _ accessUnit: YouTubeOutputH264AccessUnit,
    format: CMVideoFormatDescription
  ) throws {
    if videoWriter == nil {
      videoWriter = try H264PassthroughSegmentedMP4Writer(
        segmentDurationSeconds: segmentDurationSeconds,
        startNumber: startNumber,
        onFailure: { [weak self] error in self?.onSegment(.failure(error)) }
      ) { [weak self] segment in
        self?.receiveVideo(segment)
      }
    }
    videoWriter?.append(try Self.makeVideoSample(accessUnit, format: format))
  }

  private func receiveVideo(_ segment: SegmentedMP4Segment) {
    queue.async { [self] in
      switch segment.kind {
      case .initialization: videoInitialization = segment.data
      case .media(let number): videoSegments[number] = segment
      }
      emitAvailableSegments()
    }
  }

  private func receiveAudio(_ segment: SegmentedMP4Segment) {
    queue.async { [self] in
      switch segment.kind {
      case .initialization: audioInitialization = segment.data
      case .media(let number): audioSegments[number] = segment
      }
      emitAvailableSegments()
    }
  }

  private func emitAvailableSegments() {
    if let videoInitialization, let audioInitialization {
      do {
        onSegment(
          .success(
            SegmentedMP4Segment(
              kind: .initialization,
              data: try FragmentedMP4Multiplexer.initialization(
                video: videoInitialization, audio: audioInitialization))))
        self.videoInitialization = nil
        self.audioInitialization = nil
      } catch {
        onSegment(.failure(error))
      }
    }
    for number in Set(videoSegments.keys).intersection(audioSegments.keys).sorted() {
      guard let video = videoSegments.removeValue(forKey: number),
        let audio = audioSegments.removeValue(forKey: number)
      else { continue }
      do {
        let earliestPresentationTime = [
          video.earliestPresentationTimeSeconds, audio.earliestPresentationTimeSeconds,
        ].compactMap { $0 }.min()
        let latestPresentationEnd = [video, audio].compactMap { segment -> Double? in
          guard let start = segment.earliestPresentationTimeSeconds,
            let duration = segment.durationSeconds
          else { return nil }
          return start + duration
        }.max()
        let combinedDuration = earliestPresentationTime.flatMap { start in
          latestPresentationEnd.map { $0 - start }
        } ?? max(video.durationSeconds ?? 0, audio.durationSeconds ?? 0)
        onSegment(
          .success(
            SegmentedMP4Segment(
              kind: .media(number: number),
              data: try FragmentedMP4Multiplexer.media(video: video.data, audio: audio.data),
              durationSeconds: combinedDuration,
              earliestPresentationTimeSeconds: earliestPresentationTime)))
      } catch {
        onSegment(.failure(error))
      }
    }
  }

  private static func makeVideoFormat(
    _ format: YouTubeOutputH264Format
  ) throws -> CMVideoFormatDescription {
    guard format.parameterSets.count >= 2, format.nalUnitHeaderLength == 4 else {
      throw YouTubeOutputMediaProcessorError.invalidVideoFormat
    }
    let parameterSets = format.parameterSets.map { $0 as NSData }
    let pointers = parameterSets.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
    let sizes = parameterSets.map(\.length)
    var description: CMFormatDescription?
    let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
      allocator: kCFAllocatorDefault,
      parameterSetCount: pointers.count,
      parameterSetPointers: pointers,
      parameterSetSizes: sizes,
      nalUnitHeaderLength: format.nalUnitHeaderLength,
      formatDescriptionOut: &description
    )
    guard status == noErr, let description else {
      throw YouTubeOutputMediaProcessorError.invalidVideoFormat
    }
    return description
  }

  private static func makeVideoSample(
    _ unit: YouTubeOutputH264AccessUnit,
    format: CMVideoFormatDescription
  ) throws -> CMSampleBuffer {
    let block = try makeBlockBuffer(unit.avccData)
    var timing = CMSampleTimingInfo(
      duration: unit.duration.cmTime,
      presentationTimeStamp: unit.presentationTime.cmTime,
      decodeTimeStamp: unit.decodeTime?.cmTime ?? .invalid)
    var sample: CMSampleBuffer?
    let status = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: block,
      formatDescription: format,
      sampleCount: 1,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 1,
      sampleSizeArray: [unit.avccData.count],
      sampleBufferOut: &sample)
    guard status == noErr, let sample else {
      throw YouTubeOutputMediaProcessorError.invalidVideoSample
    }
    if !unit.isKeyFrame,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
        as? [NSMutableDictionary],
      let first = attachments.first
    {
      first[kCMSampleAttachmentKey_NotSync] = true
    }
    return sample
  }

  private static func makeAudioSample(_ buffer: YouTubeOutputPCMBuffer) throws -> CMSampleBuffer {
    guard buffer.sampleFormat == .float32Interleaved,
      buffer.sampleRate > 0,
      buffer.channelCount > 0,
      buffer.frameCount > 0,
      buffer.data.count
        == Int(buffer.frameCount) * Int(buffer.channelCount) * MemoryLayout<Float32>.size
    else { throw YouTubeOutputMediaProcessorError.invalidAudio }

    var stream = AudioStreamBasicDescription(
      mSampleRate: Double(buffer.sampleRate),
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: UInt32(buffer.channelCount) * 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(buffer.channelCount) * 4,
      mChannelsPerFrame: UInt32(buffer.channelCount),
      mBitsPerChannel: 32,
      mReserved: 0)
    var format: CMAudioFormatDescription?
    guard
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &stream,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &format) == noErr,
      let format
    else { throw YouTubeOutputMediaProcessorError.invalidAudio }
    let block = try makeBlockBuffer(buffer.data)
    var timing = CMSampleTimingInfo(
      duration: buffer.duration.cmTime,
      presentationTimeStamp: buffer.presentationTime.cmTime,
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: block,
        formatDescription: format,
        sampleCount: Int(buffer.frameCount),
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sample) == noErr,
      let sample
    else { throw YouTubeOutputMediaProcessorError.invalidAudio }
    return sample
  }

  private static func makeBlockBuffer(_ data: Data) throws -> CMBlockBuffer {
    var block: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: data.count,
        blockAllocator: nil,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: data.count,
        flags: 0,
        blockBufferOut: &block) == kCMBlockBufferNoErr,
      let block
    else { throw YouTubeOutputMediaProcessorError.blockBuffer }
    let status = data.withUnsafeBytes {
      CMBlockBufferReplaceDataBytes(
        with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
        dataLength: data.count)
    }
    guard status == kCMBlockBufferNoErr else {
      throw YouTubeOutputMediaProcessorError.blockBuffer
    }
    return block
  }
}

extension YouTubeOutputMediaTime {
  fileprivate var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
}

private final class LockedFinishResult: @unchecked Sendable {
  private let lock = NSLock()
  private var error: (any Error)?
  func record(_ result: Result<Void, any Error>) {
    if case .failure(let error) = result { lock.withLock { self.error = self.error ?? error } }
  }
  var value: Result<Void, any Error> {
    lock.withLock { error.map(Result.failure) ?? .success(()) }
  }
}

enum YouTubeOutputMediaProcessorError: Error, LocalizedError {
  case missingVideoFormat
  case invalidVideoFormat
  case invalidVideoSample
  case invalidAudio
  case blockBuffer

  var errorDescription: String? {
    switch self {
    case .missingVideoFormat: "An H.264 access unit arrived before its format."
    case .invalidVideoFormat: "The H.264 format is invalid."
    case .invalidVideoSample: "The H.264 access unit is invalid."
    case .invalidAudio: "The PCM audio buffer is invalid."
    case .blockBuffer: "The media block buffer could not be created."
    }
  }
}
