// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import Foundation

public struct RecordingRemuxer: Sendable {
  public init() {}

  public func remux(
    package: RecordingPackage,
    to outputURL: URL,
    replaceExisting: Bool = false
  ) async throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: outputURL.path) {
      guard replaceExisting else {
        throw RecordingRemuxerError.outputAlreadyExists(outputURL)
      }
    }

    let temporaryURL = outputURL.deletingLastPathComponent()
      .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp")
      .appendingPathExtension("mp4")
    defer { try? fileManager.removeItem(at: temporaryURL) }

    let groups = try await makeTrackGroups(package: package)
    try await writePassthrough(groups: groups, to: temporaryURL)
    if fileManager.fileExists(atPath: outputURL.path) {
      try fileManager.removeItem(at: outputURL)
    }
    try fileManager.moveItem(at: temporaryURL, to: outputURL)
  }

  private func makeTrackGroups(package: RecordingPackage) async throws -> [RemuxTrackGroup] {
    let timeline = try package.manifestURL.map(RecordingDASHTimeline.init(contentsOf:))
    var mainVideo: [RemuxTrackSource] = []
    var mainAudio: [RemuxTrackSource] = []
    for (url, path) in zip(package.mainMediaURLs, package.mainMediaPaths) {
      mainVideo.append(try await makeTrackSource(
        from: url, mediaPath: path, mediaType: .video, isEnabled: true, timeline: timeline))
      mainAudio.append(try await makeTrackSource(
        from: url, mediaPath: path, mediaType: .audio, isEnabled: true, timeline: timeline))
    }
    var groups = [
      RemuxTrackGroup(sources: mainVideo, mediaType: .video, isEnabled: true),
      RemuxTrackGroup(sources: mainAudio, mediaType: .audio, isEnabled: true),
    ]
    for audioTrack in package.audioTracks {
      var sources: [RemuxTrackSource] = []
      for (url, path) in zip(audioTrack.mediaURLs, audioTrack.mediaPaths) {
        sources.append(try await makeTrackSource(
          from: url,
          mediaPath: path,
          mediaType: .audio,
          isEnabled: false,
          timeline: timeline
        ))
      }
      groups.append(RemuxTrackGroup(sources: sources, mediaType: .audio, isEnabled: false))
    }
    return groups
  }

  private func makeTrackSource(
    from url: URL,
    mediaPath: String,
    mediaType: AVMediaType,
    isEnabled: Bool,
    timeline: RecordingDASHTimeline?
  ) async throws -> RemuxTrackSource {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: mediaType).first else {
      throw RecordingRemuxerError.missingTrack(url, mediaType.rawValue)
    }
    let timeRange = try await track.load(.timeRange)
    let formatDescriptions = try await track.load(.formatDescriptions)
    guard let formatDescription = formatDescriptions.first else {
      throw RecordingRemuxerError.missingFormatDescription(url, mediaType.rawValue)
    }
    return RemuxTrackSource(
      asset: asset,
      track: track,
      mediaType: mediaType,
      formatDescription: formatDescription,
      presentationStart: timeline?.presentationStart(for: mediaPath) ?? timeRange.start,
      sourceStart: timeRange.start,
      isEnabled: isEnabled
    )
  }

  private func writePassthrough(groups: [RemuxTrackGroup], to outputURL: URL) async throws {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          try Self.writePassthroughSynchronously(groups: groups, to: outputURL)
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private static func writePassthroughSynchronously(
    groups: [RemuxTrackGroup],
    to outputURL: URL
  ) throws {
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true
    let states = try groups.map { group in
      guard let source = group.sources.first else {
        throw RecordingRemuxerError.cannotCreateReaderOutput(group.mediaType.rawValue)
      }
      let input = AVAssetWriterInput(
        mediaType: group.mediaType,
        outputSettings: nil,
        sourceFormatHint: source.formatDescription
      )
      input.expectsMediaDataInRealTime = false
      input.marksOutputTrackAsEnabled = group.isEnabled
      guard writer.canAdd(input) else {
        throw RecordingRemuxerError.cannotCreateWriterInput(group.mediaType.rawValue)
      }
      writer.add(input)
      return try RemuxTrackState(group: group, input: input)
    }
    guard writer.startWriting() else {
      throw writer.error ?? RecordingRemuxerError.cannotStartWriter
    }
    writer.startSession(atSourceTime: .zero)
    var activeCount = states.count
    while activeCount > 0 {
      try throwIfWriterTerminated(writer)
      var madeProgress = false
      for state in states where !state.isFinished && state.input.isReadyForMoreMediaData {
        guard let sampleBuffer = try state.copyNextSampleBuffer() else {
          state.input.markAsFinished()
          state.isFinished = true
          activeCount -= 1
          madeProgress = true
          continue
        }
        // Readers can emit format/discontinuity marker buffers which contain no media
        // samples. They carry no payload to preserve in the remuxed file and cannot be
        // assigned normal sample timing by AVAssetWriter.
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else {
          madeProgress = true
          continue
        }
        if state.timingOffset == nil {
          // Compressed audio read through AVAssetReader retains its encoder-delay trim
          // attachment. The MPD start denotes the first playable sample, not the leading
          // AAC priming packets, so anchor that playable instant to the DASH timeline.
          let sampleStart = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
          let playableStart = CMTimeAdd(sampleStart, trimDurationAtStart(sampleBuffer))
          state.timingOffset = CMTimeSubtract(
            state.source.presentationStart,
            playableStart.isValid ? playableStart : state.source.sourceStart
          )
        }
        let offset = state.timingOffset ?? .zero
        guard let adjusted = retimed(sampleBuffer, adding: offset) else {
          throw RecordingRemuxerError.cannotRetimeSample(state.source.mediaType.rawValue)
        }
        guard state.input.append(adjusted) else {
          throw writer.error ?? RecordingRemuxerError.writerAppendFailed
        }
        madeProgress = true
      }
      if !madeProgress {
        try throwIfWriterTerminated(writer)
        Thread.sleep(forTimeInterval: 0.001)
      }
    }
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    semaphore.wait()
    guard writer.status == .completed else {
      throw writer.error ?? RecordingRemuxerError.writerFinishFailed
    }
  }

  private static func throwIfWriterTerminated(_ writer: AVAssetWriter) throws {
    switch writer.status {
    case .failed:
      throw writer.error ?? RecordingRemuxerError.writerFailed
    case .cancelled:
      throw writer.error ?? RecordingRemuxerError.writerCancelled
    default:
      break
    }
  }

  private static func retimed(_ sampleBuffer: CMSampleBuffer, adding offset: CMTime)
    -> CMSampleBuffer?
  {
    var count = 0
    guard
      CMSampleBufferGetSampleTimingInfoArray(
        sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr
    else { return nil }
    var timing: [CMSampleTimingInfo]
    if count > 0 {
      timing = Array(repeating: CMSampleTimingInfo(), count: count)
      guard
        CMSampleBufferGetSampleTimingInfoArray(
          sampleBuffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count) == noErr
      else { return nil }
    } else {
      var entry = CMSampleTimingInfo()
      guard CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &entry) == noErr
      else { return nil }
      timing = [entry]
    }
    for index in timing.indices {
      if timing[index].presentationTimeStamp.isValid {
        timing[index].presentationTimeStamp = CMTimeAdd(
          timing[index].presentationTimeStamp, offset)
      }
      if timing[index].decodeTimeStamp.isValid {
        timing[index].decodeTimeStamp = CMTimeAdd(timing[index].decodeTimeStamp, offset)
      }
    }
    var adjusted: CMSampleBuffer?
    guard
      CMSampleBufferCreateCopyWithNewTiming(
        allocator: kCFAllocatorDefault,
        sampleBuffer: sampleBuffer,
        sampleTimingEntryCount: timing.count,
        sampleTimingArray: &timing,
        sampleBufferOut: &adjusted
      ) == noErr
    else { return nil }
    return adjusted
  }

  private static func trimDurationAtStart(_ sampleBuffer: CMSampleBuffer) -> CMTime {
    guard
      let attachment = CMGetAttachment(
        sampleBuffer,
        key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
        attachmentModeOut: nil
      ),
      CFGetTypeID(attachment) == CFDictionaryGetTypeID()
    else { return .zero }
    return CMTimeMakeFromDictionary((attachment as! CFDictionary))
  }

}

private struct RemuxTrackGroup: @unchecked Sendable {
  var sources: [RemuxTrackSource]
  var mediaType: AVMediaType
  var isEnabled: Bool
}

private struct RemuxTrackSource: @unchecked Sendable {
  var asset: AVAsset
  var track: AVAssetTrack
  var mediaType: AVMediaType
  var formatDescription: CMFormatDescription
  var presentationStart: CMTime
  var sourceStart: CMTime
  var isEnabled: Bool
}

private final class RemuxTrackState: @unchecked Sendable {
  let group: RemuxTrackGroup
  let input: AVAssetWriterInput
  private var sourceIndex = 0
  private var reader: AVAssetReader?
  private var output: AVAssetReaderTrackOutput?
  var isFinished = false
  var timingOffset: CMTime?

  init(
    group: RemuxTrackGroup,
    input: AVAssetWriterInput
  ) throws {
    self.group = group
    self.input = input
    try beginSource()
  }

  var source: RemuxTrackSource { group.sources[sourceIndex] }

  func copyNextSampleBuffer() throws -> CMSampleBuffer? {
    while sourceIndex < group.sources.count {
      guard let reader, let output else {
        throw RecordingRemuxerError.cannotStartReader
      }
      if let sample = output.copyNextSampleBuffer() { return sample }
      if reader.status == .failed {
        throw reader.error ?? RecordingRemuxerError.readerFailed
      }
      sourceIndex += 1
      guard sourceIndex < group.sources.count else { return nil }
      timingOffset = nil
      try beginSource()
    }
    return nil
  }

  private func beginSource() throws {
    let source = group.sources[sourceIndex]
    let reader = try AVAssetReader(asset: source.asset)
    let output = AVAssetReaderTrackOutput(track: source.track, outputSettings: nil)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      throw RecordingRemuxerError.cannotCreateReaderOutput(source.mediaType.rawValue)
    }
    reader.add(output)
    guard reader.startReading() else {
      throw reader.error ?? RecordingRemuxerError.cannotStartReader
    }
    self.reader = reader
    self.output = output
  }
}
