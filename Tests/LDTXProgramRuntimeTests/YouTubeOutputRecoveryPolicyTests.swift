// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXYouTubeOutputProtocol
import XCTest

@testable import LDTXProgramRuntime

final class YouTubeOutputRecoveryPolicyTests: XCTestCase {
  func testFixedFourSecondDelayAdvancesGenerationAndStopsAfterThreeRetries() throws {
    var policy = YouTubeOutputRecoveryPolicy()

    XCTAssertEqual(
      try XCTUnwrap(policy.nextRetry()),
      YouTubeOutputRecoveryPolicy.Retry(attempt: 1, generation: 1, delay: 4))
    XCTAssertEqual(
      try XCTUnwrap(policy.nextRetry()),
      YouTubeOutputRecoveryPolicy.Retry(attempt: 2, generation: 2, delay: 4))
    XCTAssertEqual(
      try XCTUnwrap(policy.nextRetry()),
      YouTubeOutputRecoveryPolicy.Retry(attempt: 3, generation: 3, delay: 4))
    XCTAssertNil(policy.nextRetry())
    XCTAssertEqual(policy.generation, 3)
  }

  func testStableConnectionClearsAttemptWithoutReusingGeneration() throws {
    var policy = YouTubeOutputRecoveryPolicy()
    _ = policy.nextRetry()
    _ = policy.nextRetry()

    policy.noteStableConnection()

    XCTAssertEqual(policy.attempt, 0)
    XCTAssertEqual(
      try XCTUnwrap(policy.nextRetry()),
      YouTubeOutputRecoveryPolicy.Retry(attempt: 1, generation: 3, delay: 4))
  }

  func testCheckpointUpdateRejectsOldGenerationAndMismatchedFingerprint() throws {
    let sessionID = UUID()
    let expected = YouTubeOutputContext(sessionID: sessionID, generation: 4)
    let stale = YouTubeOutputResetRequest(
      context: YouTubeOutputContext(sessionID: sessionID, generation: 3),
      reason: "stale",
      nextMediaSegmentNumber: 12,
      configurationFingerprint: "v1:expected")
    XCTAssertNil(
      try YouTubeOutputCheckpointUpdate.validated(
        resetRequest: stale,
        expectedContext: expected,
        configurationFingerprint: "v1:expected"))

    let mismatch = YouTubeOutputResetRequest(
      context: expected,
      reason: "mismatch",
      nextMediaSegmentNumber: 13,
      configurationFingerprint: "v1:other")
    XCTAssertThrowsError(
      try YouTubeOutputCheckpointUpdate.validated(
        resetRequest: mismatch,
        expectedContext: expected,
        configurationFingerprint: "v1:expected"))
  }

  func testCheckpointUpdateAcceptsCurrentGenerationCommit() throws {
    let context = YouTubeOutputContext(sessionID: UUID(), generation: 5)
    let request = YouTubeOutputResetRequest(
      context: context,
      reason: "reset",
      nextMediaSegmentNumber: 21,
      initializationSegment: Data([1, 2]),
      configurationFingerprint: "v1:expected",
      availabilityStartTime: Date(timeIntervalSince1970: 123))

    XCTAssertEqual(
      try YouTubeOutputCheckpointUpdate.validated(
        resetRequest: request,
        expectedContext: context,
        configurationFingerprint: "v1:expected"),
      YouTubeOutputCheckpointUpdate(
        nextMediaSegmentNumber: 21,
        initializationSegment: Data([1, 2]),
        availabilityStartTime: Date(timeIntervalSince1970: 123)))
  }

  func testOnlyUnrecoverableXPCFailuresRequireGlobalStop() {
    XCTAssertTrue(OutputServiceProcessError.configurationMismatch.requiresGlobalStop)
    XCTAssertTrue(OutputServiceProcessError.resetLimitReached("failed").requiresGlobalStop)
    XCTAssertFalse(OutputServiceProcessError.unavailable.requiresGlobalStop)
    XCTAssertFalse(OutputServiceProcessError.remote("retryable").requiresGlobalStop)
    XCTAssertFalse(OutputServiceProcessError.restartRequested("retryable").requiresGlobalStop)
  }

  func testResumeGateDropsMediaBeforeFirstKeyFrame() throws {
    var gate = YouTubeOutputResumeGate()
    let batch = YouTubeOutputMediaBatch(
      context: YouTubeOutputContext(sessionID: UUID(), generation: 1),
      sequence: 0,
      video: [
        videoSample(at: 1, isKeyFrame: false),
        videoSample(at: 2, isKeyFrame: true),
        videoSample(at: 3, isKeyFrame: false),
      ],
      audio: [audioSample(at: 1), audioSample(at: 2), audioSample(at: 3)])

    let filtered = try XCTUnwrap(gate.filter(batch))

    XCTAssertEqual(filtered.video.map(\.presentationTime.value), [2, 3])
    XCTAssertEqual(filtered.audio.map(\.presentationTime.value), [2, 3])
    XCTAssertFalse(gate.requiresKeyFrame)
    XCTAssertNotNil(gate.filter(batch))
  }

  func testResumeGateWaitsForKeyFrameAgainAfterReset() {
    var gate = YouTubeOutputResumeGate()
    let nonKeyFrameBatch = YouTubeOutputMediaBatch(
      context: YouTubeOutputContext(sessionID: UUID(), generation: 1),
      sequence: 0,
      video: [videoSample(at: 1, isKeyFrame: false)],
      audio: [audioSample(at: 1)])

    XCTAssertNil(gate.filter(nonKeyFrameBatch))
    XCTAssertTrue(gate.requiresKeyFrame)

    _ = gate.filter(
      YouTubeOutputMediaBatch(
        context: nonKeyFrameBatch.context,
        sequence: 1,
        video: [videoSample(at: 2, isKeyFrame: true)]))
    XCTAssertFalse(gate.requiresKeyFrame)

    gate.reset()

    XCTAssertTrue(gate.requiresKeyFrame)
    XCTAssertNil(gate.filter(nonKeyFrameBatch))
  }

  private func videoSample(at value: Int64, isKeyFrame: Bool) -> YouTubeOutputH264AccessUnit {
    YouTubeOutputH264AccessUnit(
      presentationTime: YouTubeOutputMediaTime(value: value, timescale: 1),
      decodeTime: YouTubeOutputMediaTime(value: value, timescale: 1),
      duration: YouTubeOutputMediaTime(value: 1, timescale: 1),
      isKeyFrame: isKeyFrame,
      avccData: Data([0, 0, 0, 1]))
  }

  private func audioSample(at value: Int64) -> YouTubeOutputAACAccessUnit {
    YouTubeOutputAACAccessUnit(
      presentationTime: YouTubeOutputMediaTime(value: value, timescale: 1),
      duration: YouTubeOutputMediaTime(value: 1, timescale: 48_000),
      sampleCount: 1,
      sampleSizes: [4],
      data: Data(count: 4))
  }
}
