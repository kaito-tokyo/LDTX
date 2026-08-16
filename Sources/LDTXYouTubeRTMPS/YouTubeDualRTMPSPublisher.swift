// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum YouTubeRTMPSCanvas: String, Sendable, Equatable {
  case landscape
  case portrait
}

public struct YouTubeDualRTMPSDestinations: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let landscape: YouTubeRTMPSDestination
  public let portrait: YouTubeRTMPSDestination

  public init(
    landscape: YouTubeRTMPSDestination,
    portrait: YouTubeRTMPSDestination
  ) throws {
    guard landscape != portrait, landscape.streamName != portrait.streamName else {
      throw YouTubeRTMPSError.invalidDestination
    }
    self.landscape = landscape
    self.portrait = portrait
  }

  public var description: String { "YouTubeDualRTMPSDestinations(<redacted>)" }
  public var debugDescription: String { description }
}

public actor YouTubeDualRTMPSPublisher {
  public typealias PublisherFactory = @Sendable (YouTubeRTMPSCanvas) -> YouTubeRTMPSPublisher

  private let landscape: YouTubeRTMPSPublisher
  private let portrait: YouTubeRTMPSPublisher
  private enum State { case idle, starting, started, stopping }
  private var state = State.idle
  private var generation: UInt64 = 0
  private var stopTask: Task<Void, Never>?

  public init() {
    landscape = YouTubeRTMPSPublisher()
    portrait = YouTubeRTMPSPublisher()
  }

  public init(factory: PublisherFactory) {
    landscape = factory(.landscape)
    portrait = factory(.portrait)
  }

  public func start(
    destinations: YouTubeDualRTMPSDestinations,
    landscapeVideoFormat: YouTubeRTMPSVideoFormat,
    portraitVideoFormat: YouTubeRTMPSVideoFormat,
    landscapeAudioFormat: YouTubeRTMPSAudioFormat,
    portraitAudioFormat: YouTubeRTMPSAudioFormat
  ) async throws {
    guard state == .idle else { throw YouTubeRTMPSError.protocolFailure("dual start") }
    generation &+= 1
    let startGeneration = generation
    state = .starting
    do {
      async let landscapeStart: Void = landscape.connect(
        to: destinations.landscape,
        videoFormat: landscapeVideoFormat,
        audioFormat: landscapeAudioFormat)
      async let portraitStart: Void = portrait.connect(
        to: destinations.portrait,
        videoFormat: portraitVideoFormat,
        audioFormat: portraitAudioFormat)
      _ = try await (landscapeStart, portraitStart)
      guard generation == startGeneration, state == .starting else {
        throw YouTubeRTMPSError.notPublishing
      }
      state = .started
    } catch {
      if generation == startGeneration {
        await landscape.finish()
        if generation == startGeneration {
          await portrait.finish()
          if generation == startGeneration { state = .idle }
        }
      }
      throw error
    }
  }

  public func appendVideo(
    _ sample: YouTubeRTMPSVideoSample,
    canvas: YouTubeRTMPSCanvas
  ) async throws {
    guard state == .started else { throw YouTubeRTMPSError.notPublishing }
    let appendGeneration = generation
    do {
      switch canvas {
      case .landscape: try await landscape.appendVideo(sample)
      case .portrait: try await portrait.appendVideo(sample)
      }
    } catch {
      if generation == appendGeneration { await stop() }
      throw error
    }
  }

  public func appendAudio(
    _ sample: YouTubeRTMPSAudioSample,
    canvas: YouTubeRTMPSCanvas
  ) async throws {
    guard state == .started else { throw YouTubeRTMPSError.notPublishing }
    let appendGeneration = generation
    do {
      switch canvas {
      case .landscape: try await landscape.appendAudio(sample)
      case .portrait: try await portrait.appendAudio(sample)
      }
    } catch {
      if generation == appendGeneration { await stop() }
      throw error
    }
  }

  public func stop() async {
    if let stopTask {
      await stopTask.value
      return
    }
    guard state != .idle else { return }
    generation &+= 1
    let stopGeneration = generation
    state = .stopping
    let task = Task { await self.stopSession(generation: stopGeneration) }
    stopTask = task
    await task.value
  }

  private func stopSession(generation stopGeneration: UInt64) async {
    async let landscapeStop: Void = landscape.finish()
    async let portraitStop: Void = portrait.finish()
    _ = await (landscapeStop, portraitStop)
    guard generation == stopGeneration else { return }
    stopTask = nil
    state = .idle
  }
}
