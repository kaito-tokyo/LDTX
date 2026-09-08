// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXYouTubeOutputProtocol
import Testing

@testable import LDTXProgramRuntime

@Suite("LDTXProgramRuntimeEasyTests", .tags(.easy))
struct YouTubeOutputRecoveryPolicyTests {
  @Test func fixedFourSecondDelayAdvancesRevisionAndStopsAfterThreeRetries() throws {
    var policy = YouTubeOutputRecoveryPolicy()

    let firstRetry = policy.nextRetry()
    #expect(
      try #require(firstRetry)
        ==
      YouTubeOutputRecoveryPolicy.Retry(attempt: 1, revision: 1, delay: 4))
    let secondRetry = policy.nextRetry()
    #expect(
      try #require(secondRetry)
        ==
      YouTubeOutputRecoveryPolicy.Retry(attempt: 2, revision: 2, delay: 4))
    let thirdRetry = policy.nextRetry()
    #expect(
      try #require(thirdRetry)
        ==
      YouTubeOutputRecoveryPolicy.Retry(attempt: 3, revision: 3, delay: 4))
    #expect(policy.nextRetry() == nil)
    #expect(policy.revision == 3)
  }

  @Test func stableConnectionClearsAttemptWithoutReusingRevision() throws {
    var policy = YouTubeOutputRecoveryPolicy()
    _ = policy.nextRetry()
    _ = policy.nextRetry()

    policy.noteStableConnection()

    #expect(policy.attempt == 0)
    let retry = policy.nextRetry()
    #expect(
      try #require(retry)
        ==
      YouTubeOutputRecoveryPolicy.Retry(attempt: 1, revision: 3, delay: 4))
  }

  @Test func checkpointUpdateRejectsOldRevisionAndMismatchedFingerprint() throws {
    let sessionID = UUID()
    let expected = YouTubeOutputContext(sessionID: sessionID, revision: 4)
    let stale = YouTubeOutputResetRequest(
      context: YouTubeOutputContext(sessionID: sessionID, revision: 3),
      reason: "stale",
      nextMediaSegmentNumber: 12,
      configurationFingerprint: "v1:expected")
    #expect(
      try YouTubeOutputCheckpointUpdate.validated(
        resetRequest: stale,
        expectedContext: expected,
        configurationFingerprint: "v1:expected") == nil)

    let mismatch = YouTubeOutputResetRequest(
      context: expected,
      reason: "mismatch",
      nextMediaSegmentNumber: 13,
      configurationFingerprint: "v1:other")
    #expect(throws: (any Error).self) {
      try YouTubeOutputCheckpointUpdate.validated(
        resetRequest: mismatch,
        expectedContext: expected,
        configurationFingerprint: "v1:expected")
    }
  }

  @Test func checkpointUpdateAcceptsCurrentRevisionCommit() throws {
    let context = YouTubeOutputContext(sessionID: UUID(), revision: 5)
    let request = YouTubeOutputResetRequest(
      context: context,
      reason: "reset",
      nextMediaSegmentNumber: 21,
      initializationSegment: Data([1, 2]),
      configurationFingerprint: "v1:expected",
      availabilityStartTime: Date(timeIntervalSince1970: 123))

    #expect(
      try YouTubeOutputCheckpointUpdate.validated(
        resetRequest: request,
        expectedContext: context,
        configurationFingerprint: "v1:expected")
        ==
      YouTubeOutputCheckpointUpdate(
        nextMediaSegmentNumber: 21,
        initializationSegment: Data([1, 2]),
        availabilityStartTime: Date(timeIntervalSince1970: 123)))
  }

  @Test func onlyUnrecoverableXPCFailuresRequireGlobalStop() {
    #expect(OutputServiceProcessError.configurationMismatch.requiresGlobalStop)
    #expect(OutputServiceProcessError.resetLimitReached("failed").requiresGlobalStop)
    #expect(!OutputServiceProcessError.unavailable.requiresGlobalStop)
    #expect(!OutputServiceProcessError.remote("retryable").requiresGlobalStop)
    #expect(!OutputServiceProcessError.restartRequested("retryable").requiresGlobalStop)
  }

  @Test func resumeGateDropsMediaBeforeFirstKeyFrame() throws {
    var gate = YouTubeOutputResumeGate()
    let batch = YouTubeOutputMediaBatch(
      context: YouTubeOutputContext(sessionID: UUID(), revision: 1),
      sequence: 0,
      video: [
        videoSample(at: 1, isKeyFrame: false),
        videoSample(at: 2, isKeyFrame: true),
        videoSample(at: 3, isKeyFrame: false),
      ],
      audio: [audioSample(at: 1), audioSample(at: 2), audioSample(at: 3)])

    let nextBatch = gate.filter(batch)
    let filtered = try #require(nextBatch)

    #expect(filtered.video.map(\.presentationTime.value) == [2, 3])
    #expect(filtered.audio.map(\.presentationTime.value) == [2, 3])
    #expect(!gate.requiresKeyFrame)
    #expect(gate.filter(batch) != nil)
  }

  @Test func resumeGateWaitsForKeyFrameAgainAfterReset() {
    var gate = YouTubeOutputResumeGate()
    let nonKeyFrameBatch = YouTubeOutputMediaBatch(
      context: YouTubeOutputContext(sessionID: UUID(), revision: 1),
      sequence: 0,
      video: [videoSample(at: 1, isKeyFrame: false)],
      audio: [audioSample(at: 1)])

    #expect(gate.filter(nonKeyFrameBatch) == nil)
    #expect(gate.requiresKeyFrame)

    _ = gate.filter(
      YouTubeOutputMediaBatch(
        context: nonKeyFrameBatch.context,
        sequence: 1,
        video: [videoSample(at: 2, isKeyFrame: true)]))
    #expect(!gate.requiresKeyFrame)

    gate.reset()

    #expect(gate.requiresKeyFrame)
    #expect(gate.filter(nonKeyFrameBatch) == nil)
  }

  private func videoSample(at value: Int64, isKeyFrame: Bool) -> YouTubeOutputH264AccessUnit {
    YouTubeOutputH264AccessUnit(
      presentationTime: YouTubeOutputMediaTime(value: value, timescale: 1),
      decodeTime: YouTubeOutputMediaTime(value: value, timescale: 1),
      duration: YouTubeOutputMediaTime(value: 1, timescale: 1),
      isKeyFrame: isKeyFrame,
      avccData: Data([0, 0, 0, 1]))
  }

  private func audioSample(at value: Int64) -> YouTubeOutputPCMBuffer {
    YouTubeOutputPCMBuffer(
      presentationTime: YouTubeOutputMediaTime(value: value, timescale: 1),
      duration: YouTubeOutputMediaTime(value: 1, timescale: 48_000),
      sampleRate: 48_000,
      channelCount: 2,
      frameCount: 1,
      sampleFormat: .float32Interleaved,
      data: Data(count: 8))
  }
}
