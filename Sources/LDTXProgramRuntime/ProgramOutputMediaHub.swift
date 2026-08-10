// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXMP4
import LDTXProgram

public enum ProgramOutputEncodingConfiguration {
  public static func make(
    configuration: ProgramRuntimeConfiguration,
    startNumber: Int = 1
  ) -> SegmentedMP4WriterConfiguration {
    configuration.outputProfile.makeSegmentedMP4Configuration(startNumber: startNumber)
  }
}

public struct ProgramOutputMediaChannelLimits: Sendable, Equatable {
  public var maximumPendingEventCount: Int
  public var maximumPendingDuration: Duration
  public var drainTimeout: Duration

  public init(
    maximumPendingEventCount: Int = 10_000,
    maximumPendingDuration: Duration = .seconds(30),
    drainTimeout: Duration = .seconds(30)
  ) {
    precondition(maximumPendingEventCount > 0)
    self.maximumPendingEventCount = maximumPendingEventCount
    self.maximumPendingDuration = maximumPendingDuration
    self.drainTimeout = drainTimeout
  }

  public static let `default` = ProgramOutputMediaChannelLimits()
}

public enum ProgramOutputMediaChannelError: Error, Equatable, Sendable {
  case backlogLimitExceeded
  case drainTimedOut
}

private struct ProgramOutputSendableSampleBuffer: @unchecked Sendable {
  let value: CMSampleBuffer
}

private enum ProgramOutputMediaEvent: @unchecked Sendable {
  case mainVideo(ProgramOutputSendableSampleBuffer)
  case mainAudioMix(ProgramOutputSendableSampleBuffer)
  case control(@Sendable () -> Void)
  case outputWillStop
}

/// The Workspace-owned connection point between an Output Session and output
/// services. Each subscription has an independent serial media channel, so a
/// slow service cannot block the publisher or another service.
public final class ProgramOutputMediaHub: @unchecked Sendable {
  public struct Subscription: Hashable, Sendable {
    fileprivate let id: UUID
  }

  private final class Channel: @unchecked Sendable {
    private struct State {
      var isOpen = true
      var pendingEventCount = 0
      var pendingEnqueueInstants: [ContinuousClock.Instant] = []
      var pendingEnqueueHeadIndex = 0
      var didReportOverflow = false
      var hasMainAudioFormatDescription = false

      var oldestPendingEnqueueInstant: ContinuousClock.Instant? {
        guard pendingEnqueueInstants.indices.contains(pendingEnqueueHeadIndex) else { return nil }
        return pendingEnqueueInstants[pendingEnqueueHeadIndex]
      }

      mutating func appendPending(at instant: ContinuousClock.Instant) {
        pendingEventCount += 1
        pendingEnqueueInstants.append(instant)
      }

      mutating func completePending() {
        precondition(pendingEventCount > 0)
        pendingEventCount -= 1
        pendingEnqueueHeadIndex += 1
        if pendingEventCount == 0 {
          pendingEnqueueInstants.removeAll(keepingCapacity: true)
          pendingEnqueueHeadIndex = 0
        } else if pendingEnqueueHeadIndex >= 1_024,
          pendingEnqueueHeadIndex * 2 >= pendingEnqueueInstants.count
        {
          pendingEnqueueInstants.removeFirst(pendingEnqueueHeadIndex)
          pendingEnqueueHeadIndex = 0
        }
      }
    }

    let id: UUID
    private let limits: ProgramOutputMediaChannelLimits
    private let handlers: Handlers
    private let now: @Sendable () -> ContinuousClock.Instant
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var state = State()
    private var drainTask: Task<Result<Void, ProgramOutputMediaChannelError>, Never>?

    init(
      id: UUID,
      limits: ProgramOutputMediaChannelLimits,
      now: @escaping @Sendable () -> ContinuousClock.Instant,
      handlers: Handlers
    ) {
      self.id = id
      self.limits = limits
      self.now = now
      self.handlers = handlers
      queue = DispatchQueue(
        label: "tokyo.kaito.ldtx.ProgramOutputMediaHub.\(id.uuidString)",
        qos: .userInitiated)
    }

    @discardableResult
    func enqueue(_ event: ProgramOutputMediaEvent) -> Bool {
      let now = now()
      let outcome = lock.withLock { () -> EnqueueOutcome in
        guard state.isOpen else { return .closed }
        let exceededCount = state.pendingEventCount >= limits.maximumPendingEventCount
        let exceededDuration =
          state.oldestPendingEnqueueInstant.map {
            now - $0 >= limits.maximumPendingDuration
          } ?? false
        if exceededCount || exceededDuration {
          state.isOpen = false
          guard !state.didReportOverflow else { return .closed }
          state.didReportOverflow = true
          return .overflow
        }
        state.appendPending(at: now)
        if case .mainAudioMix(let sample) = event,
          sample.value.formatDescription != nil
        {
          state.hasMainAudioFormatDescription = true
        }
        queue.async { [self] in
          deliver(event)
          lock.withLock { state.completePending() }
        }
        return .accepted
      }
      if outcome == .overflow {
        DispatchQueue.global(qos: .userInitiated).async { [handlers] in
          handlers.failure(ProgramOutputMediaChannelError.backlogLimitExceeded)
        }
      }
      return outcome == .accepted
    }

    func hasMainAudioFormatDescription() -> Bool {
      lock.withLock { state.hasMainAudioFormatDescription }
    }

    func close() {
      lock.withLock { state.isOpen = false }
    }

    func drain() async -> Result<Void, ProgramOutputMediaChannelError> {
      let task = lock.withLock {
        state.isOpen = false
        if let drainTask { return drainTask }
        let task = Task { [queue, limits] in
          await withCheckedContinuation { continuation in
            let race = DrainRace(continuation: continuation)
            queue.async { race.finish(.success(())) }
            Task {
              try? await Task.sleep(for: limits.drainTimeout)
              race.finish(.failure(.drainTimedOut))
            }
          }
        }
        drainTask = task
        return task
      }
      return await task.value
    }

    private func deliver(_ event: ProgramOutputMediaEvent) {
      switch event {
      case .mainVideo(let sample): handlers.video(sample.value)
      case .mainAudioMix(let sample): handlers.audioMix(sample.value)
      case .control(let operation): operation()
      case .outputWillStop: handlers.outputWillStop()
      }
    }

    private enum EnqueueOutcome: Equatable { case accepted, closed, overflow }
  }

  private final class DrainRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation:
      CheckedContinuation<Result<Void, ProgramOutputMediaChannelError>, Never>?

    init(
      continuation: CheckedContinuation<Result<Void, ProgramOutputMediaChannelError>, Never>
    ) {
      self.continuation = continuation
    }

    func finish(_ result: Result<Void, ProgramOutputMediaChannelError>) {
      let continuation = lock.withLock {
        let continuation = self.continuation
        self.continuation = nil
        return continuation
      }
      continuation?.resume(returning: result)
    }
  }

  private struct Handlers: @unchecked Sendable {
    var video: @Sendable (CMSampleBuffer) -> Void
    var audioMix: @Sendable (CMSampleBuffer) -> Void
    var outputWillStop: @Sendable () -> Void
    var failure: @Sendable (Error) -> Void
  }

  private let lock = NSLock()
  private let now: @Sendable () -> ContinuousClock.Instant
  private var channelsByID: [UUID: Channel] = [:]
  private var drainingChannelsByID: [UUID: Channel] = [:]

  public convenience init() { self.init(now: { ContinuousClock().now }) }

  init(now: @escaping @Sendable () -> ContinuousClock.Instant) { self.now = now }

  public func subscribe(
    limits: ProgramOutputMediaChannelLimits = .default,
    mainVideo: @escaping @Sendable (CMSampleBuffer) -> Void,
    mainAudioMix: @escaping @Sendable (CMSampleBuffer) -> Void,
    outputWillStop: @escaping @Sendable () -> Void = {},
    failureHandler: @escaping @Sendable (Error) -> Void = { _ in }
  ) -> Subscription {
    let id = UUID()
    let channel = Channel(
      id: id,
      limits: limits,
      now: now,
      handlers: Handlers(
        video: mainVideo,
        audioMix: mainAudioMix,
        outputWillStop: outputWillStop,
        failure: failureHandler))
    lock.withLock { channelsByID[id] = channel }
    return Subscription(id: id)
  }

  public func unsubscribe(_ subscription: Subscription) {
    let channel = lock.withLock { channelsByID.removeValue(forKey: subscription.id) }
    channel?.close()
  }

  public func unsubscribeAndDrain(
    _ subscription: Subscription
  ) async -> Result<Void, ProgramOutputMediaChannelError> {
    let channel: Channel? = lock.withLock {
      if let channel = drainingChannelsByID[subscription.id] { return channel }
      guard let channel = channelsByID.removeValue(forKey: subscription.id) else { return nil }
      drainingChannelsByID[subscription.id] = channel
      return channel
    }
    guard let channel else { return .success(()) }
    let result = await channel.drain()
    lock.withLock {
      if drainingChannelsByID[subscription.id] === channel {
        drainingChannelsByID.removeValue(forKey: subscription.id)
      }
    }
    return result
  }

  func publishMainVideo(_ sampleBuffer: CMSampleBuffer) {
    publish(.mainVideo(ProgramOutputSendableSampleBuffer(value: sampleBuffer)))
  }

  func publishMainAudioMix(_ sampleBuffer: CMSampleBuffer) {
    publish(.mainAudioMix(ProgramOutputSendableSampleBuffer(value: sampleBuffer)))
  }

  func publishOutputWillStop() {
    publish(.outputWillStop)
  }

  public func enqueueControl(
    _ subscription: Subscription, operation: @escaping @Sendable () -> Void
  ) -> Bool {
    let channel = lock.withLock { channelsByID[subscription.id] }
    return channel?.enqueue(.control(operation)) ?? false
  }

  public func hasMainAudioFormatDescription(_ subscription: Subscription) -> Bool {
    let channel = lock.withLock { channelsByID[subscription.id] }
    return channel?.hasMainAudioFormatDescription() ?? false
  }

  private func publish(_ event: ProgramOutputMediaEvent) {
    let channels = lock.withLock { Array(channelsByID.values) }
    for channel in channels { channel.enqueue(event) }
  }
}
