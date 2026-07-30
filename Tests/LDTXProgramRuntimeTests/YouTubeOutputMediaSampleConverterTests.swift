// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import LDTXMP4
import LDTXYouTubeOutputProtocol
import XCTest

@testable import LDTXProgramRuntime

final class YouTubeOutputMediaSampleConverterTests: XCTestCase {
  func testConvertsEncodedH264SampleToFormatAndAccessUnit() async throws {
    let output = EncodedSampleOutput()
    let encoder = try H264VideoEncoder(
      configuration: H264VideoEncoderConfiguration(
        width: 320, height: 180, frameRate: 30, bitRate: 800_000)
    ) { output.append($0) }
    encoder.encode(
      pixelBuffer: try makePixelBuffer(width: 320, height: 180),
      presentationTime: CMTime(value: 90, timescale: 600),
      duration: CMTime(value: 20, timescale: 600))
    try await finish(encoder)
    let sample = try XCTUnwrap(try output.sampleBuffers().first)

    let format = try YouTubeOutputMediaSampleConverter.h264Format(from: sample)
    let accessUnit = try YouTubeOutputMediaSampleConverter.h264AccessUnit(from: sample)

    XCTAssertEqual(format.width, 320)
    XCTAssertEqual(format.height, 180)
    XCTAssertEqual(format.nalUnitHeaderLength, 4)
    XCTAssertGreaterThanOrEqual(format.parameterSets.count, 2)
    XCTAssertTrue(format.parameterSets.allSatisfy { !$0.isEmpty })
    XCTAssertEqual(accessUnit.presentationTime, YouTubeOutputMediaTime(value: 90, timescale: 600))
    XCTAssertEqual(accessUnit.duration, YouTubeOutputMediaTime(value: 20, timescale: 600))
    XCTAssertTrue(accessUnit.isKeyFrame)
    XCTAssertEqual(accessUnit.avccData, try data(from: sample))
    XCTAssertGreaterThan(accessUnit.avccData.count, 4)
  }

  private func finish(_ encoder: H264VideoEncoder) async throws {
    try await withCheckedThrowingContinuation { continuation in
      encoder.finish { continuation.resume(with: $0) }
    }
  }

  private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(
        kCFAllocatorDefault, width, height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
        &pixelBuffer),
      kCVReturnSuccess)
    return try XCTUnwrap(pixelBuffer)
  }

  private func data(from sample: CMSampleBuffer) throws -> Data {
    let block = try XCTUnwrap(sample.dataBuffer)
    let count = CMBlockBufferGetDataLength(block)
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes { bytes in
      CMBlockBufferCopyDataBytes(
        block, atOffset: 0, dataLength: count, destination: bytes.baseAddress!)
    }
    XCTAssertEqual(status, kCMBlockBufferNoErr)
    return data
  }
}

private final class EncodedSampleOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [Result<CMSampleBuffer, Error>] = []

  func append(_ result: Result<CMSampleBuffer, Error>) {
    lock.withLock { results.append(result) }
  }

  func sampleBuffers() throws -> [CMSampleBuffer] {
    try lock.withLock { try results.map { try $0.get() } }
  }
}
