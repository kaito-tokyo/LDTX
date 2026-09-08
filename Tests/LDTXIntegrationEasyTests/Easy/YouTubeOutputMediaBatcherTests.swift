// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import CoreMedia
import Foundation
import LDTXYouTubeOutputProtocol
import Testing

@testable import LDTXProgramRuntime

extension LDTXIntegrationEasyTests {
  @Suite
  struct YouTubeOutputMediaBatcherEasyTests {
    @Test func finishWaitsForAcceptedMediaAcknowledgement() async throws {
      let uploadStarted = DispatchSemaphore(value: 0)
      let finishCompleted = DispatchSemaphore(value: 0)
      let probe = YouTubeMediaUploadProbe { uploadStarted.signal() }
      let didFinish = LockedYouTubeBatcherFlag()
      let batcher = YouTubeOutputMediaBatcher(
        sessionID: UUID(),
        sharedVideoMemory: try ProgramOutputSharedH264Service(slotCount: 1, slotSize: 1_024),
        failureHandler: { error in Issue.record("unexpected failure: \(error)") },
        uploadMediaBatch: probe.upload(_:completionHandler:))

      batcher.appendAudio(try makeYouTubeBatcherPCMSample())
      batcher.finish {
        didFinish.set()
        finishCompleted.signal()
      }

      #expect(await waits(for: uploadStarted, timeout: 1))
      #expect(!didFinish.value)
      probe.acknowledge()
      #expect(await waits(for: finishCompleted, timeout: 1))
      #expect(didFinish.value)
    }

    @Test func mediaRejectedAfterCancelDoesNotReportOverflow() async throws {
      let cancelCompleted = DispatchSemaphore(value: 0)
      let failureReported = DispatchSemaphore(value: 0)
      let batcher = YouTubeOutputMediaBatcher(
        sessionID: UUID(),
        sharedVideoMemory: try ProgramOutputSharedH264Service(slotCount: 1, slotSize: 1_024),
        failureHandler: { _ in failureReported.signal() },
        uploadMediaBatch: { _, _ in Issue.record("cancelled batcher must not upload media") })

      batcher.cancel { cancelCompleted.signal() }
      #expect(await waits(for: cancelCompleted, timeout: 1))
      batcher.appendAudio(try makeYouTubeBatcherPCMSample())

      let didReportFailure = await waits(for: failureReported, timeout: 0.1)
      #expect(!didReportFailure)
    }

    @Test func overflowDrainsMediaAdmittedBeforeFailure() async throws {
      let uploadStarted = DispatchSemaphore(value: 0)
      let failureReported = DispatchSemaphore(value: 0)
      let probe = YouTubeMediaUploadProbe { uploadStarted.signal() }
      let sample = SendableYouTubeBatcherSample(value: try makeYouTubeBatcherPCMSample())
      let batcherReference = LockedYouTubeBatcherReference()
      let injectedOverflow = LockedYouTubeBatcherFlag()
      let batcher = YouTubeOutputMediaBatcher(
        sessionID: UUID(),
        sharedVideoMemory: try ProgramOutputSharedH264Service(slotCount: 1, slotSize: 1_024),
        failureHandler: { _ in failureReported.signal() },
        maximumPendingCount: 1,
        beforeMediaExecution: {
          guard injectedOverflow.setIfFalse(), let batcher = batcherReference.value else { return }
          batcher.appendAudio(sample.value)
        },
        uploadMediaBatch: probe.upload(_:completionHandler:))
      batcherReference.value = batcher

      batcher.appendAudio(sample.value)

      #expect(await waits(for: uploadStarted, timeout: 1))
      probe.acknowledge()
      #expect(await waits(for: failureReported, timeout: 1))

      let finishCompleted = DispatchSemaphore(value: 0)
      batcher.finish { finishCompleted.signal() }
      #expect(await waits(for: finishCompleted, timeout: 1))
    }

    @Test func finishPreservesOverflowUntilAdmittedMediaDrains() async throws {
      let uploadStarted = DispatchSemaphore(value: 0)
      let failureReported = DispatchSemaphore(value: 0)
      let finishCompleted = DispatchSemaphore(value: 0)
      let probe = YouTubeMediaUploadProbe { uploadStarted.signal() }
      let sample = SendableYouTubeBatcherSample(value: try makeYouTubeBatcherPCMSample())
      let batcherReference = LockedYouTubeBatcherReference()
      let injectedOverflow = LockedYouTubeBatcherFlag()
      let batcher = YouTubeOutputMediaBatcher(
        sessionID: UUID(),
        sharedVideoMemory: try ProgramOutputSharedH264Service(slotCount: 1, slotSize: 1_024),
        failureHandler: { _ in failureReported.signal() },
        maximumPendingCount: 1,
        beforeMediaExecution: {
          guard injectedOverflow.setIfFalse(), let batcher = batcherReference.value else { return }
          batcher.appendAudio(sample.value)
          batcher.finish { finishCompleted.signal() }
        },
        uploadMediaBatch: probe.upload(_:completionHandler:))
      batcherReference.value = batcher

      batcher.appendAudio(sample.value)

      #expect(await waits(for: uploadStarted, timeout: 1))
      probe.acknowledge()
      #expect(await waits(for: failureReported, timeout: 1))
      #expect(await waits(for: finishCompleted, timeout: 1))
    }

    private func waits(for semaphore: DispatchSemaphore, timeout: TimeInterval) async -> Bool {
      await Task.detached {
        waitForSemaphore(semaphore, timeout: timeout)
      }.value
    }
  }
}

private func waitForSemaphore(_ semaphore: DispatchSemaphore, timeout: TimeInterval) -> Bool {
  semaphore.wait(timeout: .now() + timeout) == .success
}

private final class YouTubeMediaUploadProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let uploadHandler: @Sendable () -> Void
  private var pending:
    (YouTubeOutputMediaBatch, @Sendable (Result<YouTubeOutputReply, Error>) -> Void)?

  init(uploadHandler: @escaping @Sendable () -> Void) {
    self.uploadHandler = uploadHandler
  }

  func upload(
    _ batch: YouTubeOutputMediaBatch,
    completionHandler: @escaping @Sendable (Result<YouTubeOutputReply, Error>) -> Void
  ) {
    lock.withLock { pending = (batch, completionHandler) }
    uploadHandler()
  }

  func acknowledge() {
    let pending = lock.withLock {
      let pending = self.pending
      self.pending = nil
      return pending
    }
    guard let (batch, completionHandler) = pending else { return }
    completionHandler(.success(YouTubeOutputReply(context: batch.context)))
  }
}

private final class LockedYouTubeBatcherFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = false
  var value: Bool { lock.withLock { storage } }
  func set() { lock.withLock { storage = true } }
  func setIfFalse() -> Bool {
    lock.withLock {
      guard !storage else { return false }
      storage = true
      return true
    }
  }
}

private final class LockedYouTubeBatcherReference: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: YouTubeOutputMediaBatcher?
  var value: YouTubeOutputMediaBatcher? {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

private struct SendableYouTubeBatcherSample: @unchecked Sendable {
  let value: CMSampleBuffer
}

private func makeYouTubeBatcherPCMSample() throws -> CMSampleBuffer {
  let data = Data(repeating: 0, count: 16)
  var blockBuffer: CMBlockBuffer?
  guard
    CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: data.count,
      blockAllocator: nil,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: data.count,
      flags: 0,
      blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
    let blockBuffer
  else { throw YouTubeBatcherTestError.sampleCreationFailed }
  let copyStatus = data.withUnsafeBytes { bytes in
    CMBlockBufferReplaceDataBytes(
      with: bytes.baseAddress!, blockBuffer: blockBuffer,
      offsetIntoDestination: 0, dataLength: data.count)
  }
  guard copyStatus == kCMBlockBufferNoErr else {
    throw YouTubeBatcherTestError.sampleCreationFailed
  }
  var stream = AudioStreamBasicDescription(
    mSampleRate: 48_000,
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
    mBytesPerPacket: 8,
    mFramesPerPacket: 1,
    mBytesPerFrame: 8,
    mChannelsPerFrame: 2,
    mBitsPerChannel: 32,
    mReserved: 0)
  var formatDescription: CMAudioFormatDescription?
  guard
    CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &stream,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &formatDescription) == noErr,
    let formatDescription
  else { throw YouTubeBatcherTestError.sampleCreationFailed }
  var timing = CMSampleTimingInfo(
    duration: CMTime(value: 1, timescale: 48_000),
    presentationTimeStamp: .zero,
    decodeTimeStamp: .invalid)
  var sampleBuffer: CMSampleBuffer?
  guard
    CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      formatDescription: formatDescription,
      sampleCount: 2,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 0,
      sampleSizeArray: nil,
      sampleBufferOut: &sampleBuffer) == noErr,
    let sampleBuffer
  else { throw YouTubeBatcherTestError.sampleCreationFailed }
  return sampleBuffer
}

private enum YouTubeBatcherTestError: Error {
  case sampleCreationFailed
}
