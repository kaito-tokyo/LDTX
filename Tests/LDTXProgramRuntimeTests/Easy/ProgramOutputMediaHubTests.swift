// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Testing

@testable import LDTXProgramRuntime

@Suite("LDTXProgramRuntimeEasyTests", .tags(.easy))
struct ProgramOutputMediaHubTests {
  @Test func videoAndAudioShareOneFIFOChannel() async throws {
    let received = LockedValues<String>()
    let hub = ProgramOutputMediaHub()
    let subscription = hub.subscribe(
      mainVideo: { _ in received.append("video") },
      mainAudioMix: { _ in received.append("audio") })
    let sample = try makeEmptyMediaHubSampleBuffer()

    hub.publishMainVideo(sample)
    hub.publishMainAudioMix(sample)
    hub.publishMainVideo(sample)

    assertDrainSucceeded(await hub.unsubscribeAndDrain(subscription))
    #expect(received.values == ["video", "audio", "video"])
  }

  @Test func slowSubscriberDoesNotBlockPublisherOrAnotherSubscriber() async throws {
    let slowStarted = DispatchSemaphore(value: 0)
    let releaseSlow = DispatchSemaphore(value: 0)
    let fastReceived = DispatchSemaphore(value: 0)
    let hub = ProgramOutputMediaHub()
    let slow = hub.subscribe(
      mainVideo: { _ in
        slowStarted.signal()
        releaseSlow.wait()
      },
      mainAudioMix: { _ in })
    let fast = hub.subscribe(
      mainVideo: { _ in fastReceived.signal() },
      mainAudioMix: { _ in })

    hub.publishMainVideo(try makeEmptyMediaHubSampleBuffer())

    #expect(await waits(for: slowStarted, timeout: 1))
    #expect(await waits(for: fastReceived, timeout: 1))
    releaseSlow.signal()
    assertDrainSucceeded(await hub.unsubscribeAndDrain(slow))
    assertDrainSucceeded(await hub.unsubscribeAndDrain(fast))
  }

  @Test func overflowClosesOnlyTheAffectedSubscriberAndDrainsAcceptedEvent() async throws {
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let firstCompleted = DispatchSemaphore(value: 0)
    let overflowReported = DispatchSemaphore(value: 0)
    let otherReceived = DispatchSemaphore(value: 0)
    let hub = ProgramOutputMediaHub()
    let limited = hub.subscribe(
      limits: ProgramOutputMediaChannelLimits(
        maximumPendingEventCount: 1,
        maximumPendingDuration: .seconds(30),
        drainTimeout: .seconds(1)),
      mainVideo: { _ in
        firstStarted.signal()
        releaseFirst.wait()
        firstCompleted.signal()
      },
      mainAudioMix: { _ in },
      failureHandler: { error in
        guard (error as? ProgramOutputMediaChannelError) == .backlogLimitExceeded else {
          Issue.record("Unexpected media channel error: \(error)")
          return
        }
        overflowReported.signal()
      })
    let other = hub.subscribe(
      mainVideo: { _ in otherReceived.signal() },
      mainAudioMix: { _ in })
    let sample = try makeEmptyMediaHubSampleBuffer()

    hub.publishMainVideo(sample)
    #expect(await waits(for: firstStarted, timeout: 1))
    hub.publishMainVideo(sample)
    #expect(await waits(for: overflowReported, timeout: 1))
    releaseFirst.signal()

    #expect(await waits(for: firstCompleted, timeout: 1))
    #expect(await waits(for: otherReceived, timeout: 1))
    #expect(await waits(for: otherReceived, timeout: 1))
    assertDrainSucceeded(await hub.unsubscribeAndDrain(limited))
    assertDrainSucceeded(await hub.unsubscribeAndDrain(other))
  }

  @Test func drainTimeoutDoesNotWaitForeverForAStalledConsumer() async throws {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let hub = ProgramOutputMediaHub()
    let subscription = hub.subscribe(
      limits: ProgramOutputMediaChannelLimits(
        maximumPendingEventCount: 10,
        maximumPendingDuration: .seconds(30),
        drainTimeout: .milliseconds(20)),
      mainVideo: { _ in
        started.signal()
        release.wait()
      },
      mainAudioMix: { _ in })
    hub.publishMainVideo(try makeEmptyMediaHubSampleBuffer())
    #expect(await waits(for: started, timeout: 1))

    if case .failure(let error) = await hub.unsubscribeAndDrain(subscription) {
      #expect(error == .drainTimedOut)
    } else {
      Issue.record("Expected drain timeout")
    }
    release.signal()
  }

  @Test func concurrentDrainsJoinTheSameAcceptedMediaDrain() async throws {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let firstCompleted = LockedMediaHubFlag()
    let secondCompleted = LockedMediaHubFlag()
    let hub = ProgramOutputMediaHub()
    let subscription = hub.subscribe(
      limits: ProgramOutputMediaChannelLimits(drainTimeout: .seconds(1)),
      mainVideo: { _ in
        started.signal()
        release.wait()
      },
      mainAudioMix: { _ in })
    hub.publishMainVideo(try makeEmptyMediaHubSampleBuffer())
    #expect(await waits(for: started, timeout: 1))

    let first = Task {
      let result = await hub.unsubscribeAndDrain(subscription)
      firstCompleted.set()
      return result
    }
    try await Task.sleep(for: .milliseconds(20))
    let second = Task {
      let result = await hub.unsubscribeAndDrain(subscription)
      secondCompleted.set()
      return result
    }
    try await Task.sleep(for: .milliseconds(20))

    #expect(!firstCompleted.value)
    #expect(!secondCompleted.value)
    release.signal()
    assertDrainSucceeded(await first.value)
    assertDrainSucceeded(await second.value)
  }

  @Test func pendingDurationTracksTheCurrentHeadDuringContinuousBacklog() async throws {
    let firstStarted = DispatchSemaphore(value: 0)
    let secondStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let releaseSecond = DispatchSemaphore(value: 0)
    let deliveryCount = LockedMediaHubCounter()
    let failures = LockedValues<ProgramOutputMediaChannelError>()
    let clock = LockedMediaHubInstant()
    let hub = ProgramOutputMediaHub(now: { clock.now })
    let subscription = hub.subscribe(
      limits: ProgramOutputMediaChannelLimits(
        maximumPendingEventCount: 10,
        maximumPendingDuration: .milliseconds(200),
        drainTimeout: .seconds(1)),
      mainVideo: { _ in
        switch deliveryCount.increment() {
        case 1:
          firstStarted.signal()
          releaseFirst.wait()
        case 2:
          secondStarted.signal()
          releaseSecond.wait()
        default:
          break
        }
      },
      mainAudioMix: { _ in },
      failureHandler: { error in
        if let error = error as? ProgramOutputMediaChannelError { failures.append(error) }
      })
    let sample = try makeEmptyMediaHubSampleBuffer()

    hub.publishMainVideo(sample)
    #expect(await waits(for: firstStarted, timeout: 1))
    clock.advance(by: .milliseconds(150))
    hub.publishMainVideo(sample)
    releaseFirst.signal()
    #expect(await waits(for: secondStarted, timeout: 1))
    clock.advance(by: .milliseconds(70))
    hub.publishMainVideo(sample)
    releaseSecond.signal()

    assertDrainSucceeded(await hub.unsubscribeAndDrain(subscription))
    #expect(deliveryCount.value == 3)
    #expect(failures.values.isEmpty)
  }

  private func waits(for semaphore: DispatchSemaphore, timeout: TimeInterval) async -> Bool {
    await Task.detached { waitForMediaHubSemaphore(semaphore, timeout: timeout) }.value
  }
}

private func assertDrainSucceeded(
  _ result: Result<Void, ProgramOutputMediaChannelError>
) {
  if case .failure(let error) = result {
    Issue.record("Expected drain success, got \(error)")
  }
}

private func waitForMediaHubSemaphore(_ semaphore: DispatchSemaphore, timeout: TimeInterval) -> Bool {
  semaphore.wait(timeout: .now() + timeout) == .success
}

private final class LockedValues<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Value] = []

  var values: [Value] { lock.withLock { storage } }
  func append(_ value: Value) { lock.withLock { storage.append(value) } }
}

private final class LockedMediaHubCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0
  var value: Int { lock.withLock { storage } }
  func increment() -> Int {
    lock.withLock {
      storage += 1
      return storage
    }
  }
}

private final class LockedMediaHubFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = false
  var value: Bool { lock.withLock { storage } }
  func set() { lock.withLock { storage = true } }
}

private final class LockedMediaHubInstant: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = ContinuousClock().now
  var now: ContinuousClock.Instant { lock.withLock { storage } }
  func advance(by duration: Duration) {
    lock.withLock { storage = storage.advanced(by: duration) }
  }
}

private func makeEmptyMediaHubSampleBuffer() throws -> CMSampleBuffer {
  var sampleBuffer: CMSampleBuffer?
  let status = CMSampleBufferCreate(
    allocator: kCFAllocatorDefault,
    dataBuffer: nil,
    dataReady: true,
    makeDataReadyCallback: nil,
    refcon: nil,
    formatDescription: nil,
    sampleCount: 0,
    sampleTimingEntryCount: 0,
    sampleTimingArray: nil,
    sampleSizeEntryCount: 0,
    sampleSizeArray: nil,
    sampleBufferOut: &sampleBuffer)
  guard status == noErr, let sampleBuffer else {
    throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
  }
  return sampleBuffer
}
