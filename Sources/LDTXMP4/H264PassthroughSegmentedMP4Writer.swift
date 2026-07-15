// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import CoreMedia
import Foundation

public enum H264PassthroughSegmentedMP4WriterError: Error, LocalizedError {
  case invalidConfiguration
  case invalidSample
  case cannotAddInput
  case writerFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration: "The H.264 passthrough writer configuration is invalid."
    case .invalidSample: "The H.264 passthrough writer received an invalid sample."
    case .cannotAddInput: "The H.264 passthrough writer cannot add its video input."
    case .writerFailed(let reason): "The H.264 passthrough writer failed: \(reason)"
    }
  }
}

public final class H264PassthroughSegmentedMP4Writer: NSObject, AVAssetWriterDelegate,
  @unchecked Sendable
{
  public typealias SegmentHandler = @Sendable (SegmentedMP4Segment) -> Void

  private let assetWriter: AVAssetWriter
  private let segmentDurationSeconds: Int
  private let startNumber: Int
  private let onSegment: SegmentHandler
  private let onFailure: @Sendable (any Error) -> Void
  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.H264PassthroughSegmentedMP4Writer")
  private var videoInput: AVAssetWriterInput?
  private var pending: [CMSampleBuffer] = []
  private var nextSegmentNumber: Int
  private var isFinishing = false
  private var storedFailure: (any Error)?
  private var finishHandler: (@Sendable (Result<Void, any Error>) -> Void)?

  public init(
    segmentDurationSeconds: Int,
    startNumber: Int = 1,
    onFailure: @escaping @Sendable (any Error) -> Void = { _ in },
    onSegment: @escaping SegmentHandler
  ) throws {
    guard segmentDurationSeconds > 0, startNumber > 0 else {
      throw H264PassthroughSegmentedMP4WriterError.invalidConfiguration
    }
    self.segmentDurationSeconds = segmentDurationSeconds
    self.startNumber = startNumber
    self.onSegment = onSegment
    self.onFailure = onFailure
    nextSegmentNumber = startNumber
    assetWriter = AVAssetWriter(contentType: .mpeg4Movie)
    assetWriter.outputFileTypeProfile = .mpeg4AppleHLS
    assetWriter.preferredOutputSegmentInterval = CMTime(
      seconds: Double(segmentDurationSeconds),
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
      } catch {
        fail(error)
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
            durationSeconds: Self.durationSeconds(from: segmentReport)
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
      seconds: Double(segmentDurationSeconds),
      preferredTimescale: 1
    )
    guard assetWriter.canAdd(input) else {
      throw H264PassthroughSegmentedMP4WriterError.cannotAddInput
    }
    assetWriter.add(input)
    assetWriter.initialSegmentStartTime = sampleBuffer.presentationTimeStamp
    do {
      try assetWriter.start()
    } catch {
      throw H264PassthroughSegmentedMP4WriterError.writerFailed(error.localizedDescription)
    }
    assetWriter.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
    videoInput = input
    input.requestMediaDataWhenReady(on: queue) { [weak self] in
      self?.drain()
      self?.finishWhenDrained()
    }
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
    drain()
    guard pending.isEmpty else { return }
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
    assetWriter.cancelWriting()
    onFailure(error)
    if let finishHandler {
      self.finishHandler = nil
      finishHandler(.failure(error))
    }
  }

  private static func durationSeconds(from report: AVAssetSegmentReport?) -> Double? {
    report?.trackReports.map(\.duration.seconds).filter { $0.isFinite && $0 > 0 }.max()
  }
}

private struct SendableCompressedSampleBuffer: @unchecked Sendable {
  var value: CMSampleBuffer
}
