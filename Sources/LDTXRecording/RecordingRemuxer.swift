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

    let sources = try await makeTrackSources(package: package)
    try await writePassthrough(sources: sources, to: temporaryURL)
    if fileManager.fileExists(atPath: outputURL.path) {
      try fileManager.removeItem(at: outputURL)
    }
    try fileManager.moveItem(at: temporaryURL, to: outputURL)
  }

  public func makeComposition(package: RecordingPackage) async throws -> AVMutableComposition {
    let composition = AVMutableComposition()
    let timeline = try package.manifestURL.map(RecordingDASHTimeline.init(contentsOf:))
    try await insertFirstTrack(
      from: package.mainMediaURL,
      mediaPath: package.mainMediaPath,
      mediaType: .video,
      isEnabled: true,
      timeline: timeline,
      into: composition
    )
    for (index, audioTrack) in package.audioTracks.enumerated() {
      try await insertFirstTrack(
        from: audioTrack.mediaURL,
        mediaPath: audioTrack.mediaPath,
        mediaType: .audio,
        isEnabled: index == 0,
        timeline: timeline,
        into: composition
      )
    }
    return composition
  }

  private func makeTrackSources(package: RecordingPackage) async throws -> [RemuxTrackSource] {
    let timeline = try package.manifestURL.map(RecordingDASHTimeline.init(contentsOf:))
    var sources = [
      try await makeTrackSource(
        from: package.mainMediaURL,
        mediaPath: package.mainMediaPath,
        mediaType: .video,
        isEnabled: true,
        timeline: timeline
      )
    ]
    for (index, audioTrack) in package.audioTracks.enumerated() {
      sources.append(
        try await makeTrackSource(
          from: audioTrack.mediaURL,
          mediaPath: audioTrack.mediaPath,
          mediaType: .audio,
          isEnabled: index == 0,
          timeline: timeline
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

  private func insertFirstTrack(
    from url: URL,
    mediaPath: String,
    mediaType: AVMediaType,
    isEnabled: Bool,
    timeline: RecordingDASHTimeline?,
    into composition: AVMutableComposition
  ) async throws {
    let asset = AVURLAsset(url: url)
    guard let sourceTrack = try await asset.loadTracks(withMediaType: mediaType).first else {
      throw RecordingRemuxerError.missingTrack(url, mediaType.rawValue)
    }
    let timeRange = try await sourceTrack.load(.timeRange)
    guard
      let destinationTrack = composition.addMutableTrack(
        withMediaType: mediaType,
        preferredTrackID: kCMPersistentTrackID_Invalid
      )
    else {
      throw RecordingRemuxerError.cannotCreateCompositionTrack(mediaType.rawValue)
    }
    let presentationStart = timeline?.presentationStart(for: mediaPath) ?? timeRange.start
    try destinationTrack.insertTimeRange(timeRange, of: sourceTrack, at: presentationStart)
    destinationTrack.isEnabled = isEnabled
  }
}

public enum RecordingRemuxerError: Error, LocalizedError, Equatable, Sendable {
  case outputAlreadyExists(URL)
  case missingTrack(URL, String)
  case missingFormatDescription(URL, String)
  case cannotCreateCompositionTrack(String)
  case cannotCreateExportSession
  case cannotCreateReaderOutput(String)
  case cannotCreateWriterInput(String)
  case cannotStartWriter
  case cannotStartReader
  case readerFailed
  case cannotRetimeSample(String)
  case writerAppendFailed
  case writerFailed
  case writerCancelled
  case writerFinishFailed
  case invalidManifest(String)

  public var errorDescription: String? {
    switch self {
    case .outputAlreadyExists(let url):
      "Output already exists: \(url.path)"
    case .missingTrack(let url, let mediaType):
      "No \(mediaType) track was found in \(url.path)."
    case .missingFormatDescription(let url, let mediaType):
      "No \(mediaType) format description was found in \(url.path)."
    case .cannotCreateCompositionTrack(let mediaType):
      "A \(mediaType) composition track could not be created."
    case .cannotCreateExportSession:
      "A passthrough MP4 export session could not be created."
    case .cannotCreateReaderOutput(let mediaType):
      "A passthrough reader output could not be created for \(mediaType)."
    case .cannotCreateWriterInput(let mediaType):
      "A passthrough writer input could not be created for \(mediaType)."
    case .cannotStartWriter:
      "The passthrough MP4 writer could not start."
    case .cannotStartReader:
      "A passthrough media reader could not start."
    case .readerFailed:
      "A passthrough media reader failed."
    case .cannotRetimeSample(let mediaType):
      "A \(mediaType) sample could not be placed on the recording timeline."
    case .writerAppendFailed:
      "The passthrough MP4 writer rejected a sample."
    case .writerFailed:
      "The passthrough MP4 writer failed."
    case .writerCancelled:
      "The passthrough MP4 writer was cancelled."
    case .writerFinishFailed:
      "The passthrough MP4 writer could not finish."
    case .invalidManifest(let reason):
      "The MPEG-DASH manifest is invalid: \(reason)"
    }
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
