// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import XCTest

@testable import LDTXProgramRuntime

final class ProgramOutputMediaHubTests: XCTestCase {
  func testVideoAndAudioShareOneFIFOChannel() async throws {
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
    XCTAssertEqual(received.values, ["video", "audio", "video"])
  }

  func testSlowSubscriberDoesNotBlockPublisherOrAnotherSubscriber() async throws {
    let slowStarted = expectation(description: "slow subscriber started")
    let releaseSlow = DispatchSemaphore(value: 0)
    let fastReceived = expectation(description: "fast subscriber received")
    let hub = ProgramOutputMediaHub()
    let slow = hub.subscribe(
      mainVideo: { _ in
        slowStarted.fulfill()
        releaseSlow.wait()
      },
      mainAudioMix: { _ in })
    let fast = hub.subscribe(
      mainVideo: { _ in fastReceived.fulfill() },
      mainAudioMix: { _ in })

    hub.publishMainVideo(try makeEmptyMediaHubSampleBuffer())

    await fulfillment(of: [slowStarted, fastReceived], timeout: 1)
    releaseSlow.signal()
    assertDrainSucceeded(await hub.unsubscribeAndDrain(slow))
    assertDrainSucceeded(await hub.unsubscribeAndDrain(fast))
  }

  func testOverflowClosesOnlyTheAffectedSubscriberAndDrainsAcceptedEvent() async throws {
    let firstStarted = expectation(description: "first event started")
    let releaseFirst = DispatchSemaphore(value: 0)
    let firstCompleted = expectation(description: "first event completed")
    let overflowReported = expectation(description: "overflow reported")
    let otherReceived = expectation(description: "other subscriber received both events")
    otherReceived.expectedFulfillmentCount = 2
    let hub = ProgramOutputMediaHub()
    let limited = hub.subscribe(
      limits: ProgramOutputMediaChannelLimits(
        maximumPendingEventCount: 1,
        maximumPendingDuration: .seconds(30),
        drainTimeout: .seconds(1)),
      mainVideo: { _ in
        firstStarted.fulfill()
        releaseFirst.wait()
        firstCompleted.fulfill()
      },
      mainAudioMix: { _ in },
      failureHandler: { error in
        XCTAssertEqual(error as? ProgramOutputMediaChannelError, .backlogLimitExceeded)
        overflowReported.fulfill()
      })
    let other = hub.subscribe(
      mainVideo: { _ in otherReceived.fulfill() },
      mainAudioMix: { _ in })
    let sample = try makeEmptyMediaHubSampleBuffer()

    hub.publishMainVideo(sample)
    await fulfillment(of: [firstStarted], timeout: 1)
    hub.publishMainVideo(sample)
    await fulfillment(of: [overflowReported], timeout: 1)
    releaseFirst.signal()

    await fulfillment(of: [firstCompleted, otherReceived], timeout: 1)
    assertDrainSucceeded(await hub.unsubscribeAndDrain(limited))
    assertDrainSucceeded(await hub.unsubscribeAndDrain(other))
  }

  func testDrainTimeoutDoesNotWaitForeverForAStalledConsumer() async throws {
    let started = expectation(description: "consumer started")
    let release = DispatchSemaphore(value: 0)
    let hub = ProgramOutputMediaHub()
    let subscription = hub.subscribe(
      limits: ProgramOutputMediaChannelLimits(
        maximumPendingEventCount: 10,
        maximumPendingDuration: .seconds(30),
        drainTimeout: .milliseconds(20)),
      mainVideo: { _ in
        started.fulfill()
        release.wait()
      },
      mainAudioMix: { _ in })
    hub.publishMainVideo(try makeEmptyMediaHubSampleBuffer())
    await fulfillment(of: [started], timeout: 1)

    if case .failure(let error) = await hub.unsubscribeAndDrain(subscription) {
      XCTAssertEqual(error, .drainTimedOut)
    } else {
      XCTFail("Expected drain timeout")
    }
    release.signal()
  }
}

private func assertDrainSucceeded(
  _ result: Result<Void, ProgramOutputMediaChannelError>,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  if case .failure(let error) = result {
    XCTFail("Expected drain success, got \(error)", file: file, line: line)
  }
}

private final class LockedValues<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Value] = []

  var values: [Value] { lock.withLock { storage } }
  func append(_ value: Value) { lock.withLock { storage.append(value) } }
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
