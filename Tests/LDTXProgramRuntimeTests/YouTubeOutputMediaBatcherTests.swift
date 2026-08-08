// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import CoreMedia
import Foundation
import LDTXYouTubeOutputProtocol
import XCTest

@testable import LDTXProgramRuntime

final class YouTubeOutputMediaBatcherTests: XCTestCase {
  func testFinishWaitsForAcceptedMediaAcknowledgement() async throws {
    let uploadStarted = expectation(description: "accepted media uploaded")
    let finishCompleted = expectation(description: "batcher drain completed")
    let probe = YouTubeMediaUploadProbe { uploadStarted.fulfill() }
    let didFinish = LockedYouTubeBatcherFlag()
    let batcher = YouTubeOutputMediaBatcher(
      sessionID: UUID(),
      sharedVideoMemory: try ProgramOutputSharedH264Service(slotCount: 1, slotSize: 1_024),
      failureHandler: { error in XCTFail("unexpected failure: \(error)") },
      uploadMediaBatch: probe.upload(_:completionHandler:))

    batcher.appendAudio(try makeYouTubeBatcherPCMSample())
    batcher.finish {
      didFinish.set()
      finishCompleted.fulfill()
    }

    await fulfillment(of: [uploadStarted], timeout: 1)
    XCTAssertFalse(didFinish.value)
    probe.acknowledge()
    await fulfillment(of: [finishCompleted], timeout: 1)
    XCTAssertTrue(didFinish.value)
  }
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
