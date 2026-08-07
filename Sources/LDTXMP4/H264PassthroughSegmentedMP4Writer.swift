// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import CoreMedia
import Foundation

public enum H264PassthroughSegmentedMP4WriterError: Error, LocalizedError {
  case invalidConfiguration
  case invalidSample
  case invalidState
  case cannotAddInput
  case pendingSamplesExceededLimit
  case writerFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration: "The H.264 passthrough writer configuration is invalid."
    case .invalidSample: "The H.264 passthrough writer received an invalid sample."
    case .invalidState: "The H.264 passthrough writer is not ready for its first sample."
    case .cannotAddInput: "The H.264 passthrough writer cannot add its video input."
    case .pendingSamplesExceededLimit:
      "The H.264 passthrough writer exceeded its pending media limit."
    case .writerFailed(let reason): "The H.264 passthrough writer failed: \(reason)"
    }
  }
}

enum H264PassthroughPendingSampleLimit {
  static let maximumDuration = CMTime(seconds: 30, preferredTimescale: 600)
  static let maximumCount = 10_000

  static func isExceeded(count: Int, earliestPresentationTime: CMTime, latestPresentationTime: CMTime)
    -> Bool
  {
    guard count <= maximumCount else { return true }
    guard earliestPresentationTime.isNumeric, latestPresentationTime.isNumeric else { return false }
    return latestPresentationTime - earliestPresentationTime > maximumDuration
  }
}

public final class H264PassthroughSegmentedMP4Writer: NSObject, AVAssetWriterDelegate,
  @unchecked Sendable
{
  public typealias SegmentHandler = @Sendable (SegmentedMP4Segment) -> Void

  private let assetWriter: AVAssetWriter
  private let targetSegmentDurationSeconds: Int
  private let startNumber: Int
  private let onSegment: SegmentHandler
  private let onFailure: @Sendable (any Error) -> Void
  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.H264PassthroughSegmentedMP4Writer")
  private var videoInput: AVAssetWriterInput?
  private var pending: [CMSampleBuffer] = []
  private var nextSegmentNumber: Int
  private var isFinishing = false
  private var isDrainScheduled = false
  private var storedFailure: (any Error)?
  private var finishHandler: (@Sendable (Result<Void, any Error>) -> Void)?

  public init(
    targetSegmentDurationSeconds: Int,
    startNumber: Int = 1,
    onFailure: @escaping @Sendable (any Error) -> Void = { _ in },
    onSegment: @escaping SegmentHandler
  ) throws {
    guard targetSegmentDurationSeconds > 0, startNumber > 0 else {
      throw H264PassthroughSegmentedMP4WriterError.invalidConfiguration
    }
    self.targetSegmentDurationSeconds = targetSegmentDurationSeconds
    self.startNumber = startNumber
    self.onSegment = onSegment
    self.onFailure = onFailure
    nextSegmentNumber = startNumber
    assetWriter = AVAssetWriter(contentType: .mpeg4Movie)
    assetWriter.outputFileTypeProfile = .mpeg4AppleHLS
    assetWriter.preferredOutputSegmentInterval = CMTime(
      seconds: Double(targetSegmentDurationSeconds),
      preferredTimescale: 1
    )
    super.init()
    assetWriter.delegate = self
  }

  public func append(_ sampleBuffer: CMSampleBuffer) {
    let sampleBuffer = SendableCompressedSampleBuffer(value: sampleBuffer)
    queue.async { [self] in
      guard !isFinishing, storedFailure == nil else { return }
      do {
        if videoInput == nil {
          try start(with: sampleBuffer.value)
        }
        pending.append(sampleBuffer.value)
        drain()
        guard validatePendingSamples() else { return }
        scheduleDrainIfNeeded()
      } catch {
        fail(error)
      }
    }
  }

  /// Starts the writer and accepts its first sample before returning.
  ///
  /// Initialization failures are returned to the caller without reporting an
  /// asynchronous writer failure because the owner has not committed this
  /// writer as active yet.
  public func appendFirst(_ sampleBuffer: CMSampleBuffer) throws {
    let sampleBuffer = SendableCompressedSampleBuffer(value: sampleBuffer)
    try queue.sync { [self] in
      guard !isFinishing, storedFailure == nil, videoInput == nil, pending.isEmpty else {
        throw H264PassthroughSegmentedMP4WriterError.invalidState
      }
      do {
        try start(with: sampleBuffer.value)
        guard let videoInput, videoInput.append(sampleBuffer.value) else {
          throw H264PassthroughSegmentedMP4WriterError.writerFailed(
            assetWriter.error?.localizedDescription ?? "append failed")
        }
      } catch {
        storedFailure = error
        pending.removeAll()
        if assetWriter.status == .writing {
          assetWriter.cancelWriting()
        }
        throw error
      }
    }
  }

  public func finish(
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    queue.async { [self] in
      guard !isFinishing else {
        completionHandler(.success(()))
        return
      }
      isFinishing = true
      if let storedFailure {
        completionHandler(.failure(storedFailure))
        return
      }
      finishHandler = completionHandler
      finishWhenDrained()
    }
  }

  public func assetWriter(
    _ writer: AVAssetWriter,
    didOutputSegmentData segmentData: Data,
    segmentType: AVAssetSegmentType,
    segmentReport: AVAssetSegmentReport?
  ) {
    queue.async { [self] in
      switch segmentType {
      case .initialization:
        onSegment(SegmentedMP4Segment(kind: .initialization, data: segmentData))
      case .separable:
        let number = nextSegmentNumber
        nextSegmentNumber += 1
        onSegment(
          SegmentedMP4Segment(
            kind: .media(number: number),
            data: segmentData,
            durationSeconds: Self.durationSeconds(from: segmentReport),
            earliestPresentationTimeSeconds: Self.earliestPresentationTimeSeconds(
              from: segmentReport)
          ))
      @unknown default:
        break
      }
    }
  }

  private func start(with sampleBuffer: CMSampleBuffer) throws {
    guard CMSampleBufferDataIsReady(sampleBuffer),
      let formatDescription = sampleBuffer.formatDescription,
      CMFormatDescriptionGetMediaSubType(formatDescription) == kCMVideoCodecType_H264,
      sampleBuffer.presentationTimeStamp.isValid
    else {
      throw H264PassthroughSegmentedMP4WriterError.invalidSample
    }
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: nil,
      sourceFormatHint: formatDescription
    )
    input.expectsMediaDataInRealTime = true
    input.preferredMediaChunkDuration = CMTime(
      seconds: Double(targetSegmentDurationSeconds),
      preferredTimescale: 1
    )
    guard assetWriter.canAdd(input) else {
      throw H264PassthroughSegmentedMP4WriterError.cannotAddInput
    }
    assetWriter.add(input)
    assetWriter.initialSegmentStartTime = .zero
    do {
      try assetWriter.start()
    } catch {
      throw H264PassthroughSegmentedMP4WriterError.writerFailed(error.localizedDescription)
    }
    assetWriter.startSession(atSourceTime: .zero)
    videoInput = input
  }

  private func scheduleDrainIfNeeded() {
    guard !pending.isEmpty, !isDrainScheduled, storedFailure == nil else { return }
    isDrainScheduled = true
    queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
      guard let self else { return }
      self.isDrainScheduled = false
      self.drain()
      self.finishWhenDrained()
      self.scheduleDrainIfNeeded()
    }
  }

  private func validatePendingSamples() -> Bool {
    guard let first = pending.first, let last = pending.last else { return true }
    guard !H264PassthroughPendingSampleLimit.isExceeded(
      count: pending.count,
      earliestPresentationTime: first.presentationTimeStamp,
      latestPresentationTime: last.presentationTimeStamp
    ) else {
      fail(H264PassthroughSegmentedMP4WriterError.pendingSamplesExceededLimit)
      return false
    }
    return true
  }

  private func drain() {
    guard let videoInput, assetWriter.status == .writing else { return }
    while videoInput.isReadyForMoreMediaData, !pending.isEmpty {
      let sampleBuffer = pending.removeFirst()
      guard videoInput.append(sampleBuffer) else {
        fail(
          H264PassthroughSegmentedMP4WriterError.writerFailed(
            assetWriter.error?.localizedDescription ?? "append failed"))
        return
      }
    }
  }

  private func finishWhenDrained() {
    guard isFinishing, let finishHandler else { return }
    guard let videoInput else {
      self.finishHandler = nil
      finishHandler(.success(()))
      return
    }
    if assetWriter.status == .failed || assetWriter.status == .cancelled {
      fail(
        H264PassthroughSegmentedMP4WriterError.writerFailed(
          assetWriter.error?.localizedDescription ?? "writer stopped before pending media drained"))
      return
    }
    drain()
    guard pending.isEmpty else {
      scheduleDrainIfNeeded()
      return
    }
    self.finishHandler = nil
    videoInput.markAsFinished()
    assetWriter.finishWriting { [self] in
      queue.async {
        if self.assetWriter.status == .failed {
          let error = H264PassthroughSegmentedMP4WriterError.writerFailed(
            self.assetWriter.error?.localizedDescription ?? "finish failed")
          self.fail(error)
          finishHandler(.failure(error))
        } else {
          finishHandler(.success(()))
        }
      }
    }
  }

  private func fail(_ error: Error) {
    guard storedFailure == nil else { return }
    storedFailure = error
    pending.removeAll()
    if assetWriter.status == .writing {
      assetWriter.cancelWriting()
    }
    onFailure(error)
    if let finishHandler {
      self.finishHandler = nil
      finishHandler(.failure(error))
    }
  }

  private static func durationSeconds(from report: AVAssetSegmentReport?) -> Double? {
    report?.trackReports.map(\.duration.seconds).filter { $0.isFinite && $0 > 0 }.max()
  }

  private static func earliestPresentationTimeSeconds(
    from report: AVAssetSegmentReport?
  ) -> Double? {
    report?.trackReports.map(\.earliestPresentationTimeStamp.seconds).filter(\.isFinite).min()
  }

}

private struct SendableCompressedSampleBuffer: @unchecked Sendable {
  var value: CMSampleBuffer
}
