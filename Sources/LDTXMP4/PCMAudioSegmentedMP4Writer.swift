// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import CoreMedia
import Foundation

public final class PCMAudioSegmentedMP4Writer: NSObject, AVAssetWriterDelegate, @unchecked Sendable
{
  public typealias SegmentHandler = @Sendable (SegmentedMP4Segment) -> Void

  private let assetWriter: AVAssetWriter
  private let audioInput: AVAssetWriterInput
  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.PCMAudioSegmentedMP4Writer")
  private let onSegment: SegmentHandler
  private let onFailure: @Sendable (any Error) -> Void
  private var pending: [CMSampleBuffer] = []
  private var nextSegmentNumber: Int
  private var didStartSession = false
  private var isFinishing = false
  private var storedFailure: Error?
  private var finishHandler: (@Sendable (Result<Void, any Error>) -> Void)?

  public init(
    formatDescription: CMAudioFormatDescription,
    bitRate: Int = 128_000,
    segmentDurationSeconds: Int,
    startNumber: Int = 1,
    onFailure: @escaping @Sendable (any Error) -> Void = { _ in },
    onSegment: @escaping SegmentHandler
  ) throws {
    guard
      let description = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?
        .pointee,
      description.mSampleRate > 0,
      description.mChannelsPerFrame > 0,
      bitRate > 0,
      segmentDurationSeconds > 0,
      startNumber > 0
    else {
      throw PCMAudioSegmentedMP4WriterError.invalidConfiguration
    }
    self.onSegment = onSegment
    self.onFailure = onFailure
    nextSegmentNumber = startNumber
    assetWriter = AVAssetWriter(contentType: .mpeg4Movie)
    assetWriter.outputFileTypeProfile = .mpeg4AppleHLS
    assetWriter.preferredOutputSegmentInterval = CMTime(
      seconds: Double(segmentDurationSeconds), preferredTimescale: 1)
    assetWriter.initialSegmentStartTime = .zero
    audioInput = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: description.mSampleRate,
        AVNumberOfChannelsKey: Int(description.mChannelsPerFrame),
        AVEncoderBitRateKey: bitRate,
      ],
      sourceFormatHint: formatDescription
    )
    audioInput.expectsMediaDataInRealTime = true
    super.init()
    assetWriter.delegate = self
    guard assetWriter.canAdd(audioInput) else {
      throw PCMAudioSegmentedMP4WriterError.cannotAddInput
    }
    assetWriter.add(audioInput)
  }

  public func append(_ sampleBuffer: CMSampleBuffer) {
    let sampleBuffer = SendablePCMSampleBuffer(value: sampleBuffer)
    queue.async { [self] in
      guard !isFinishing, storedFailure == nil else { return }
      if !didStartSession {
        assetWriter.initialSegmentStartTime = sampleBuffer.value.presentationTimeStamp
        do {
          try assetWriter.start()
        } catch {
          fail(PCMAudioSegmentedMP4WriterError.writerFailed(error.localizedDescription))
          return
        }
        assetWriter.startSession(atSourceTime: sampleBuffer.value.presentationTimeStamp)
        didStartSession = true
        audioInput.requestMediaDataWhenReady(on: queue) { [weak self] in
          self?.drain()
          self?.finishWhenDrained()
        }
      }
      pending.append(sampleBuffer.value)
      drain()
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

  func cancel(with error: any Error) {
    queue.async { [self] in fail(error) }
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
            durationSeconds: Self.durationSeconds(from: segmentReport)))
      @unknown default:
        break
      }
    }
  }

  private func drain() {
    guard assetWriter.status == .writing else { return }
    while audioInput.isReadyForMoreMediaData, !pending.isEmpty {
      if !audioInput.append(pending.removeFirst()) {
        fail(
          PCMAudioSegmentedMP4WriterError.writerFailed(
            assetWriter.error?.localizedDescription ?? "append failed"))
        return
      }
    }
  }

  private func finishWhenDrained() {
    guard isFinishing, let finishHandler else { return }
    drain()
    guard pending.isEmpty else { return }
    self.finishHandler = nil
    guard didStartSession else {
      assetWriter.cancelWriting()
      finishHandler(.success(()))
      return
    }
    audioInput.markAsFinished()
    assetWriter.finishWriting { [self] in
      queue.async {
        if self.assetWriter.status == .failed {
          let error = PCMAudioSegmentedMP4WriterError.writerFailed(
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
    finishHandler?(.failure(error))
    finishHandler = nil
  }

  private static func durationSeconds(from report: AVAssetSegmentReport?) -> Double? {
    report?.trackReports.map(\.duration.seconds).filter { $0.isFinite && $0 > 0 }.max()
  }
}

public enum PCMAudioSegmentedMP4WriterError: Error, LocalizedError {
  case invalidConfiguration
  case cannotAddInput
  case writerFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration: "The PCM audio writer configuration is invalid."
    case .cannotAddInput: "The PCM audio writer cannot add its input."
    case .writerFailed(let reason): "The PCM audio writer failed: \(reason)"
    }
  }
}

private struct SendablePCMSampleBuffer: @unchecked Sendable {
  var value: CMSampleBuffer
}
