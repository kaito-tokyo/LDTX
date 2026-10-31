// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import UniformTypeIdentifiers

public struct AudioTrackRecordResult: Sendable {
  public let inputUID: String
  public let sampleRate: Double
  public let channels: UInt32
  public let receivedFrames: Int64
  public let elapsed: Duration
  public let outputURL: URL
}

public enum AudioTrackRecorderError: Error, LocalizedError {
  case invalidConfiguration
  case writerStartFailed(String)
  case appendFailed(String)
  case noSamples
  case writerFinishFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration: "The audio track recorder configuration is invalid."
    case .writerStartFailed(let message): "The audio writer failed to start: \(message)"
    case .appendFailed(let message): "The audio writer failed to append: \(message)"
    case .noSamples: "The audio input produced no samples."
    case .writerFinishFailed(let message): "The audio writer failed to finish: \(message)"
    }
  }
}

public final class AudioTrackRecorder: @unchecked Sendable {
  private let engine: AudioEngine
  private let inputUID: String
  private let outputURL: URL
  private let sampleRate: Double
  private let channels: UInt32
  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.audio-track-recorder")
  private var writer: AVAssetWriter?
  private var receiver: AVAssetWriterInput.SampleBufferReceiver?
  private var subscription: AudioEngine.Subscription?
  private var receivedFrames: Int64 = 0
  private var startedAt: ContinuousClock.Instant?
  private var failed: Error?

  public init(
    engine: AudioEngine,
    inputUID: String,
    outputURL: URL,
    sampleRate: Double = 48_000,
    channels: UInt32 = 2
  ) throws {
    guard !inputUID.isEmpty, sampleRate > 0, channels > 0 else {
      throw AudioTrackRecorderError.invalidConfiguration
    }
    self.engine = engine
    self.inputUID = inputUID
    self.outputURL = outputURL
    self.sampleRate = sampleRate
    self.channels = channels
  }

  public func record(for duration: Duration) async throws -> AudioTrackRecordResult {
    guard duration > .zero else { throw AudioTrackRecorderError.invalidConfiguration }
    let input = engine.addInput(uid: inputUID, sampleRate: sampleRate, channels: channels)
    let deadline = ContinuousClock.now + duration
    while !engine.hasActiveInput(uid: inputUID) && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    guard engine.hasActiveInput(uid: inputUID) else {
      throw AudioTrackRecorderError.writerStartFailed("Input device is not active")
    }
    try prepareWriter()
    startedAt = .now
    subscription = engine.subscribe(input: input) { [weak self] sample in
      self?.append(sample)
    }
    try await Task.sleep(for: duration)
    return try await finish()
  }

  public func finish() async throws -> AudioTrackRecordResult {
    subscription?.cancel()
    subscription = nil
    let state = queue.sync { () -> (AVAssetWriter?, AVAssetWriterInput.SampleBufferReceiver?, Error?) in
      (writer, receiver, failed)
    }
    guard state.2 == nil, let writer = state.0, let receiver = state.1 else {
      throw state.2 ?? AudioTrackRecorderError.writerFinishFailed("not started")
    }
    receiver.finish()
    await writer.finishWriting()
    guard writer.status == .completed else {
      throw AudioTrackRecorderError.writerFinishFailed(
        writer.error?.localizedDescription ?? "unknown writer error")
    }
    let result = makeResult()
    engine.stop()
    return result
  }

  private func prepareWriter() throws {
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
    let input = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVEncoderBitRateKey: 128_000
      ])
    guard writer.canAdd(input) else { throw AudioTrackRecorderError.invalidConfiguration }
    let receiver = writer.inputReceiver(for: input)
    try writer.start()
    guard writer.status == .writing else {
      throw AudioTrackRecorderError.writerStartFailed(
        writer.error?.localizedDescription ?? "unknown writer error")
    }
    writer.startSession(atSourceTime: .zero)
    self.writer = writer
    self.receiver = receiver
  }

  private func append(_ sample: CMSampleBuffer) {
    let sample = SendableSampleBuffer(value: sample)
    queue.async { [self] in
      guard failed == nil, let receiver else { return }
      do {
        let ready = CMReadySampleBuffer(unsafeBuffer: sample.value)
        guard try receiver.appendImmediately(ready) else {
          throw AudioTrackRecorderError.appendFailed("receiver is not ready")
        }
        receivedFrames += Int64(CMSampleBufferGetNumSamples(sample.value))
      } catch {
        failed = error
      }
    }
  }

  private struct SendableSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
  }

  private func makeResult() -> AudioTrackRecordResult {
    AudioTrackRecordResult(
      inputUID: inputUID,
      sampleRate: sampleRate,
      channels: channels,
      receivedFrames: receivedFrames,
      elapsed: startedAt.map { .now - $0 } ?? .zero,
      outputURL: outputURL)
  }
}
