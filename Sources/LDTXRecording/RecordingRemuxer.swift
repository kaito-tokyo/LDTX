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
    try await remux(
      package: package,
      to: outputURL,
      replaceExisting: replaceExisting,
      canvas: nil
    )
  }

  public func remux(
    package: RecordingPackage,
    to outputURL: URL,
    replaceExisting: Bool = false,
    canvas: RecordingCanvas?
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

    let sources = try await makeTrackSources(package: package, canvas: canvas)
    try await writePassthrough(sources: sources, to: temporaryURL)
    if fileManager.fileExists(atPath: outputURL.path) {
      try fileManager.removeItem(at: outputURL)
    }
    try fileManager.moveItem(at: temporaryURL, to: outputURL)
  }

  private func makeTrackSources(
    package: RecordingPackage,
    canvas: RecordingCanvas?
  ) async throws -> [RemuxTrackSource] {
    let selectedMedia: (path: String, url: URL)
    if package.formatVersion == 3 {
      let available = package.availableCanvases
      let selectedCanvas: RecordingCanvas
      if let canvas {
        selectedCanvas = canvas
      } else if available.count == 1, let onlyCanvas = available.first {
        selectedCanvas = onlyCanvas
      } else {
        throw RecordingRemuxerError.canvasSelectionRequired
      }
      guard let media = package.media(for: selectedCanvas) else {
        throw RecordingRemuxerError.canvasUnavailable(selectedCanvas)
      }
      selectedMedia = media
    } else {
      selectedMedia = (package.mainMediaPath, package.mainMediaURL)
    }
    let timeline = try package.manifestURL.map(RecordingDASHTimeline.init(contentsOf:))
    var sources = [
      try await makeTrackSource(
        from: selectedMedia.url,
        mediaPath: selectedMedia.path,
        mediaType: .video,
        isEnabled: true,
        timeline: timeline
      )
    ]
    let audioTracks =
      package.formatVersion == 3
      ? package.audioTracks.filter { track in
        track.mediaURL == selectedMedia.url
          || (track.mediaURL != package.landscapeMediaURL
            && track.mediaURL != package.portraitMediaURL)
      }
      : package.audioTracks
    for (index, audioTrack) in audioTracks.enumerated() {
      let audioTimeline =
        audioTrack.mediaURL == package.mainMediaURL ? nil : timeline
      sources.append(
        try await makeTrackSource(
          from: audioTrack.mediaURL,
          mediaPath: audioTrack.mediaPath,
          mediaType: .audio,
          isEnabled: index == 0,
          timeline: audioTimeline
        ))
    }
    return sources
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

  private func writePassthrough(sources: [RemuxTrackSource], to outputURL: URL) async throws {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          try Self.writePassthroughSynchronously(sources: sources, to: outputURL)
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private static func writePassthroughSynchronously(
    sources: [RemuxTrackSource],
    to outputURL: URL
  ) throws {
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true
    let states = try sources.map { source in
      let reader = try AVAssetReader(asset: source.asset)
      let output = AVAssetReaderTrackOutput(track: source.track, outputSettings: nil)
      output.alwaysCopiesSampleData = false
      guard reader.canAdd(output) else {
        throw RecordingRemuxerError.cannotCreateReaderOutput(source.mediaType.rawValue)
      }
      reader.add(output)
      let input = AVAssetWriterInput(
        mediaType: source.mediaType,
        outputSettings: nil,
        sourceFormatHint: source.formatDescription
      )
      input.expectsMediaDataInRealTime = false
      input.marksOutputTrackAsEnabled = source.isEnabled
      guard writer.canAdd(input) else {
        throw RecordingRemuxerError.cannotCreateWriterInput(source.mediaType.rawValue)
      }
      writer.add(input)
      return RemuxTrackState(source: source, reader: reader, output: output, input: input)
    }
    guard writer.startWriting() else {
      throw writer.error ?? RecordingRemuxerError.cannotStartWriter
    }
    writer.startSession(atSourceTime: .zero)
    for state in states where !state.reader.startReading() {
      throw state.reader.error ?? RecordingRemuxerError.cannotStartReader
    }

    var activeCount = states.count
    while activeCount > 0 {
      try throwIfWriterTerminated(writer)
      var madeProgress = false
      for state in states where !state.isFinished && state.input.isReadyForMoreMediaData {
        guard let sampleBuffer = state.output.copyNextSampleBuffer() else {
          if state.reader.status == .failed {
            throw state.reader.error ?? RecordingRemuxerError.readerFailed
          }
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
  let source: RemuxTrackSource
  let reader: AVAssetReader
  let output: AVAssetReaderTrackOutput
  let input: AVAssetWriterInput
  var isFinished = false
  var timingOffset: CMTime?

  init(
    source: RemuxTrackSource,
    reader: AVAssetReader,
    output: AVAssetReaderTrackOutput,
    input: AVAssetWriterInput
  ) {
    self.source = source
    self.reader = reader
    self.output = output
    self.input = input
  }
}
