// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import XCTest

/// Generates black video and silent audio so the menu test can open a real player.
@MainActor
func makeMenuSmokeMedia(at url: URL) async throws {
  let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  let video = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32,
    ])
  let audio = AVAssetWriterInput(
    mediaType: .audio,
    outputSettings: [
      AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
    ])
  let pixels = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: video,
    sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
  writer.add(video)
  writer.add(audio)
  guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
  defer { if writer.status == .writing { writer.cancelWriting() } }
  writer.startSession(atSourceTime: .zero)

  var pixelBuffer: CVPixelBuffer?
  XCTAssertEqual(
    CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess
  )
  let frame = try XCTUnwrap(pixelBuffer)
  CVPixelBufferLockBaseAddress(frame, [])
  memset(CVPixelBufferGetBaseAddress(frame), 0, CVPixelBufferGetDataSize(frame))
  CVPixelBufferUnlockBaseAddress(frame, [])

  var format = AudioStreamBasicDescription(
    mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
    mBitsPerChannel: 16, mReserved: 0)
  var description: CMAudioFormatDescription?
  XCTAssertEqual(
    CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, asbd: &format, layoutSize: 0, layout: nil,
      magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description),
    noErr)
  var block: CMBlockBuffer?
  let byteCount = 96_000 * 4
  XCTAssertEqual(
    CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
      blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
      dataLength: byteCount, flags: 0, blockBufferOut: &block), kCMBlockBufferNoErr)
  let data = try XCTUnwrap(block)
  XCTAssertEqual(
    CMBlockBufferFillDataBytes(
      with: 0, blockBuffer: data, offsetIntoDestination: 0, dataLength: byteCount),
    kCMBlockBufferNoErr)
  var timing = CMSampleTimingInfo(
    duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: .zero,
    decodeTimeStamp: .invalid)
  var sampleSize = 4
  var sample: CMSampleBuffer?
  XCTAssertEqual(
    CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault, dataBuffer: data, formatDescription: description,
      sampleCount: 96_000, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample), noErr)

  func waitUntilReady(_ input: AVAssetWriterInput) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !input.isReadyForMoreMediaData {
      guard writer.status == .writing, ContinuousClock.now < deadline else {
        throw writer.error ?? CocoaError(.fileWriteUnknown)
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
  try await waitUntilReady(audio)
  guard audio.append(try XCTUnwrap(sample)) else {
    throw writer.error ?? CocoaError(.fileWriteUnknown)
  }
  audio.markAsFinished()
  for second in 0..<2 {
    try await waitUntilReady(video)
    guard pixels.append(frame, withPresentationTime: CMTime(value: Int64(second), timescale: 1))
    else {
      throw writer.error ?? CocoaError(.fileWriteUnknown)
    }
  }
  video.markAsFinished()
  writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
  await writer.finishWriting()
  guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}
