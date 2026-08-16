// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXMP4
import LDTXYouTubeRTMPS

protocol YouTubeDualRTMPSPublishing: Sendable {
  func start(
    destinations: YouTubeDualRTMPSDestinations,
    landscapeVideoFormat: YouTubeRTMPSVideoFormat,
    portraitVideoFormat: YouTubeRTMPSVideoFormat,
    landscapeAudioFormat: YouTubeRTMPSAudioFormat,
    portraitAudioFormat: YouTubeRTMPSAudioFormat
  ) async throws
  func appendVideo(_ sample: YouTubeRTMPSVideoSample, canvas: YouTubeRTMPSCanvas) async throws
  func appendAudio(_ sample: YouTubeRTMPSAudioSample, canvas: YouTubeRTMPSCanvas) async throws
  func stop() async
}

extension YouTubeDualRTMPSPublisher: YouTubeDualRTMPSPublishing {}

public enum YouTubeRTMPSWorkspaceServiceError: Error, LocalizedError, Equatable {
  case pendingMediaLimitExceeded
  case stopped

  public var errorDescription: String? {
    switch self {
    case .pendingMediaLimitExceeded:
      "YouTube RTMPS reached its pending media limit."
    case .stopped:
      "The YouTube RTMPS output service has already stopped."
    }
  }
}

/// Converts and serially delivers both Workspace Canvas outputs to one YouTube
/// Dual stream publisher. The service starts both publishers atomically after
/// receiving the H.264 and PCM formats for both Canvases.
public final class YouTubeRTMPSWorkspaceService: @unchecked Sendable {
  public typealias FailureHandler = @Sendable (any Error) -> Void

  private struct SendableSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
  }

  private let lock = NSLock()
  private let core: Core
  private let pendingMediaLimit: Int
  private var tail: Task<Void, Never>?
  private var acceptsMedia = true
  private var queuedMediaCount = 0

  public convenience init(
    destinations: YouTubeDualRTMPSDestinations,
    pendingMediaLimit: Int = 3_600,
    failureHandler: @escaping FailureHandler
  ) {
    self.init(
      destinations: destinations,
      publisher: YouTubeDualRTMPSPublisher(),
      pendingMediaLimit: pendingMediaLimit,
      failureHandler: failureHandler)
  }

  init(
    destinations: YouTubeDualRTMPSDestinations,
    publisher: any YouTubeDualRTMPSPublishing,
    pendingMediaLimit: Int = 3_600,
    failureHandler: @escaping FailureHandler
  ) {
    precondition(pendingMediaLimit > 0)
    self.pendingMediaLimit = pendingMediaLimit
    core = Core(
      destinations: destinations,
      publisher: publisher,
      pendingMediaLimit: pendingMediaLimit,
      failureHandler: failureHandler)
  }

  public func appendLandscapeVideo(_ sampleBuffer: CMSampleBuffer) {
    let sample = SendableSampleBuffer(value: sampleBuffer)
    enqueueMedia { await $0.appendVideo(sample.value, canvas: .landscape) }
  }

  public func appendPortraitVideo(_ sampleBuffer: CMSampleBuffer) {
    let sample = SendableSampleBuffer(value: sampleBuffer)
    enqueueMedia { await $0.appendVideo(sample.value, canvas: .portrait) }
  }

  public func appendLandscapeAudioMix(_ sampleBuffer: CMSampleBuffer) {
    let sample = SendableSampleBuffer(value: sampleBuffer)
    enqueueMedia { await $0.appendAudio(sample.value, canvas: .landscape) }
  }

  public func appendPortraitAudioMix(_ sampleBuffer: CMSampleBuffer) {
    let sample = SendableSampleBuffer(value: sampleBuffer)
    enqueueMedia { await $0.appendAudio(sample.value, canvas: .portrait) }
  }

  public func failMediaDelivery(_ error: any Error) {
    lock.withLock {
      guard acceptsMedia else { return }
      acceptsMedia = false
      let preceding = tail
      let core = core
      tail = Task {
        await preceding?.value
        await core.reportFailure(error)
      }
    }
  }

  public func finish() async -> Result<Void, any Error> {
    let task: Task<Void, Never> = lock.withLock {
      acceptsMedia = false
      let preceding = tail
      let core = core
      let task = Task {
        await preceding?.value
        await core.finish()
      }
      tail = task
      return task
    }
    await task.value
    return await core.result
  }

  private func enqueueMedia(
    _ operation: @escaping @Sendable (Core) async -> Void
  ) {
    lock.withLock {
      guard acceptsMedia else { return }
      guard queuedMediaCount < pendingMediaLimit else {
        acceptsMedia = false
        let preceding = tail
        let core = core
        tail = Task {
          await preceding?.value
          await core.reportFailure(YouTubeRTMPSWorkspaceServiceError.pendingMediaLimitExceeded)
        }
        return
      }
      queuedMediaCount += 1
      let preceding = tail
      let core = core
      tail = Task {
        await preceding?.value
        await operation(core)
        self.lock.withLock { self.queuedMediaCount -= 1 }
      }
    }
  }

  private actor Core {
    private enum PendingMedia: Sendable {
      case video(YouTubeRTMPSVideoSample, YouTubeRTMPSCanvas)
      case audio(YouTubeRTMPSAudioSample, YouTubeRTMPSCanvas)
    }

    private struct CanvasState {
      var videoFormat: YouTubeRTMPSVideoFormat?
      var audioEncoder: AACAudioEncoder?
      var audioFormat: YouTubeRTMPSAudioFormat?
    }

    private let destinations: YouTubeDualRTMPSDestinations
    private let publisher: any YouTubeDualRTMPSPublishing
    private let pendingMediaLimit: Int
    private let failureHandler: FailureHandler
    private var landscape = CanvasState()
    private var portrait = CanvasState()
    private var pendingMedia: [PendingMedia] = []
    private var isPublishing = false
    private var isFinished = false
    private var failure: (any Error)?

    init(
      destinations: YouTubeDualRTMPSDestinations,
      publisher: any YouTubeDualRTMPSPublishing,
      pendingMediaLimit: Int,
      failureHandler: @escaping FailureHandler
    ) {
      self.destinations = destinations
      self.publisher = publisher
      self.pendingMediaLimit = pendingMediaLimit
      self.failureHandler = failureHandler
    }

    var result: Result<Void, any Error> {
      if let failure { return .failure(failure) }
      return .success(())
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer, canvas: YouTubeRTMPSCanvas) async {
      guard canAcceptMedia else { return }
      do {
        if videoFormat(for: canvas) == nil {
          setVideoFormat(
            try YouTubeOutputMediaSampleConverter.rtmpsVideoFormat(from: sampleBuffer),
            for: canvas)
        }
        try await deliverOrBuffer(
          .video(
            try YouTubeOutputMediaSampleConverter.rtmpsVideoSample(from: sampleBuffer), canvas))
        try await startIfReady()
      } catch {
        await reportFailure(error)
      }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer, canvas: YouTubeRTMPSCanvas) async {
      guard canAcceptMedia else { return }
      do {
        let encoder = try audioEncoder(for: canvas, sampleBuffer: sampleBuffer)
        for sample in try encoder.encode(sampleBuffer) {
          for packet in try YouTubeOutputMediaSampleConverter.rtmpsAudioSamples(from: sample) {
            try await deliverOrBuffer(.audio(packet, canvas))
          }
        }
        try await startIfReady()
      } catch {
        await reportFailure(error)
      }
    }

    func finish() async {
      guard !isFinished else { return }
      isFinished = true
      guard failure == nil else {
        await publisher.stop()
        return
      }
      do {
        try await finishAudio(canvas: .landscape)
        try await finishAudio(canvas: .portrait)
        try await startIfReady()
      } catch {
        await reportFailure(error)
      }
      await publisher.stop()
    }

    private var canAcceptMedia: Bool { !isFinished && failure == nil }

    private func audioEncoder(
      for canvas: YouTubeRTMPSCanvas,
      sampleBuffer: CMSampleBuffer
    ) throws -> AACAudioEncoder {
      if let encoder = state(for: canvas).audioEncoder { return encoder }
      guard let format = sampleBuffer.formatDescription else {
        throw YouTubeOutputMediaSampleConverterError.missingFormatDescription
      }
      let encoder = try AACAudioEncoder(inputFormatDescription: format)
      let audioFormat = try YouTubeOutputMediaSampleConverter.rtmpsAudioFormat(
        from: encoder.outputFormatDescription)
      setAudioEncoder(encoder, format: audioFormat, for: canvas)
      return encoder
    }

    private func finishAudio(canvas: YouTubeRTMPSCanvas) async throws {
      guard let encoder = state(for: canvas).audioEncoder else { return }
      for sample in try encoder.finish() {
        for packet in try YouTubeOutputMediaSampleConverter.rtmpsAudioSamples(from: sample) {
          try await deliverOrBuffer(.audio(packet, canvas))
        }
      }
    }

    private func startIfReady() async throws {
      guard !isPublishing,
        let landscapeVideoFormat = landscape.videoFormat,
        let portraitVideoFormat = portrait.videoFormat,
        let landscapeAudioFormat = landscape.audioFormat,
        let portraitAudioFormat = portrait.audioFormat
      else { return }
      try await publisher.start(
        destinations: destinations,
        landscapeVideoFormat: landscapeVideoFormat,
        portraitVideoFormat: portraitVideoFormat,
        landscapeAudioFormat: landscapeAudioFormat,
        portraitAudioFormat: portraitAudioFormat)
      isPublishing = true
      let buffered = pendingMedia
      pendingMedia.removeAll(keepingCapacity: false)
      for media in buffered { try await deliver(media) }
    }

    private func deliverOrBuffer(_ media: PendingMedia) async throws {
      if isPublishing {
        try await deliver(media)
        return
      }
      guard pendingMedia.count < pendingMediaLimit else {
        throw YouTubeRTMPSWorkspaceServiceError.pendingMediaLimitExceeded
      }
      pendingMedia.append(media)
    }

    private func deliver(_ media: PendingMedia) async throws {
      switch media {
      case .video(let sample, let canvas):
        try await publisher.appendVideo(sample, canvas: canvas)
      case .audio(let sample, let canvas):
        try await publisher.appendAudio(sample, canvas: canvas)
      }
    }

    func reportFailure(_ error: any Error) async {
      guard failure == nil else { return }
      failure = error
      pendingMedia.removeAll(keepingCapacity: false)
      await publisher.stop()
      failureHandler(error)
    }

    private func state(for canvas: YouTubeRTMPSCanvas) -> CanvasState {
      switch canvas {
      case .landscape: landscape
      case .portrait: portrait
      }
    }

    private func videoFormat(for canvas: YouTubeRTMPSCanvas) -> YouTubeRTMPSVideoFormat? {
      state(for: canvas).videoFormat
    }

    private func setVideoFormat(
      _ format: YouTubeRTMPSVideoFormat,
      for canvas: YouTubeRTMPSCanvas
    ) {
      switch canvas {
      case .landscape: landscape.videoFormat = format
      case .portrait: portrait.videoFormat = format
      }
    }

    private func setAudioEncoder(
      _ encoder: AACAudioEncoder,
      format: YouTubeRTMPSAudioFormat,
      for canvas: YouTubeRTMPSCanvas
    ) {
      switch canvas {
      case .landscape:
        landscape.audioEncoder = encoder
        landscape.audioFormat = format
      case .portrait:
        portrait.audioEncoder = encoder
        portrait.audioFormat = format
      }
    }
  }
}
