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

  private let startNumber: Int
  private let onSegment: SegmentHandler
  private var writer: MuxedPassthroughSegmentedMP4Writer?
  private var audioEncoder: AACAudioEncoder?
  private var muxedVideoFormat: CMVideoFormatDescription?
  private var pendingVideoSamples: [CMSampleBuffer] = []
  private var pendingAudioSamples: [CMSampleBuffer] = []
  private var videoFormat: CMVideoFormatDescription?
  private var pendingVideoFormat: CMVideoFormatDescription?
  private var videoFrameHold = YouTubeOutputVideoFrameHold()
  private var mediaTimeline: YouTubeOutputMediaTimeline

  init(
    startNumber: Int,
    outputOffset: YouTubeOutputMediaTime = YouTubeOutputMediaTime(value: 1, timescale: 1),
    onSegment: @escaping SegmentHandler
  ) {
    self.startNumber = startNumber
    mediaTimeline = YouTubeOutputMediaTimeline(outputOffset: outputOffset)
    self.onSegment = onSegment
  }

  func append(_ batch: YouTubeOutputMediaBatch) throws {
    var videoSamples: [CMSampleBuffer] = []
    var audioSamples: [CMSampleBuffer] = []
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
        videoSamples.append(try Self.makeVideoSample(ready, format: pendingVideoFormat))
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
      if audioEncoder == nil {
        guard let format = sample.formatDescription else {
          throw YouTubeOutputMediaProcessorError.invalidAudio
        }
        audioEncoder = try AACAudioEncoder(inputFormatDescription: format)
      }
      audioSamples.append(contentsOf: try audioEncoder?.encode(sample) ?? [])
    }
    try appendEncoded(video: videoSamples, audio: audioSamples)
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
      var finalVideo: [CMSampleBuffer] = []
      if let final = videoFrameHold.finish() {
        guard let pendingVideoFormat else {
          throw YouTubeOutputMediaProcessorError.missingVideoFormat
        }
        finalVideo.append(try Self.makeVideoSample(final, format: pendingVideoFormat))
      }
      let finalAudio = try audioEncoder?.finish() ?? []
      try appendEncoded(video: finalVideo, audio: finalAudio)
    } catch {
      completion(.failure(error))
      return
    }
    guard let writer else {
      completion(
        pendingVideoSamples.isEmpty && pendingAudioSamples.isEmpty
          ? .success(()) : .failure(YouTubeOutputMediaProcessorError.incompleteMedia))
      return
    }
    writer.finish(completionHandler: completion)
  }

  private func appendEncoded(
    video: [CMSampleBuffer],
    audio: [CMSampleBuffer]
  ) throws {
    if muxedVideoFormat == nil {
      muxedVideoFormat = video.first?.formatDescription
    }
    pendingVideoSamples.append(contentsOf: video)
    pendingAudioSamples.append(contentsOf: audio)
    if writer == nil, let muxedVideoFormat, let audioFormat = audioEncoder?.outputFormatDescription
    {
      writer = try MuxedPassthroughSegmentedMP4Writer(
        videoFormatDescription: muxedVideoFormat,
        audioFormatDescription: audioFormat,
        startNumber: startNumber,
        onFailure: { [weak self] error in self?.onSegment(.failure(error)) }
      ) { [weak self] segment in
        self?.onSegment(.success(segment))
      }
    }
    guard let writer else { return }
    if !pendingVideoSamples.isEmpty || !pendingAudioSamples.isEmpty {
      writer.append(video: pendingVideoSamples, audio: pendingAudioSamples)
      pendingVideoSamples.removeAll(keepingCapacity: true)
      pendingAudioSamples.removeAll(keepingCapacity: true)
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
    guard !data.isEmpty else { throw YouTubeOutputMediaProcessorError.invalidVideoSample }
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
    let status = data.withUnsafeBytes { bytes -> OSStatus in
      guard let baseAddress = bytes.baseAddress else {
        return kCMBlockBufferBadPointerParameterErr
      }
      return CMBlockBufferReplaceDataBytes(
        with: baseAddress, blockBuffer: block, offsetIntoDestination: 0,
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

enum YouTubeOutputMediaProcessorError: Error, LocalizedError {
  case missingVideoFormat
  case invalidVideoFormat
  case invalidVideoSample
  case invalidAudio
  case incompleteMedia
  case blockBuffer

  var errorDescription: String? {
    switch self {
    case .missingVideoFormat: "An H.264 access unit arrived before its format."
    case .invalidVideoFormat: "The H.264 format is invalid."
    case .invalidVideoSample: "The H.264 access unit is invalid."
    case .invalidAudio: "The PCM audio buffer is invalid."
    case .incompleteMedia: "The YouTube stream did not receive both video and audio."
    case .blockBuffer: "The media block buffer could not be created."
    }
  }
}
