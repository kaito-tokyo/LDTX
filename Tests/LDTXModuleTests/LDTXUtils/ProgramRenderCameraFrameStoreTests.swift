// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Foundation
@testable import LDTXUtils
import Metal
import Testing

@Suite(.tags(.hard)) struct ProgramRenderCameraFrameStoreIntegrationTestSuite {
  @Test(
    "LUB-1053: Negotiated1080p is converted to requested720p",
    arguments: [
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_32BGRA,
    ])
  func negotiated1080pIsConvertedToRequested720p(format: OSType) throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let store = ProgramRenderCameraFrameStore(width: 1280, height: 720, device: device)
    let input = try buffer(width: 1920, height: 1080, format: format)
    fill(input, luma: format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 16 : 0)
    store.copyAndYield(input)
    let frame = try #require(try store.wait(timeout: 1))
    #expect(CVPixelBufferGetWidth(frame.pixelBuffer) == 1280)
    #expect(CVPixelBufferGetHeight(frame.pixelBuffer) == 720)
    #expect(
      CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    #expect(abs(Int(firstLuma(frame.pixelBuffer))) <= 1)
    #expect(frame.pixelBuffer !== input)
    #expect(
      CFEqual(
        CVBufferCopyAttachment(frame.pixelBuffer, kCVImageBufferTransferFunctionKey, nil),
        kCVImageBufferTransferFunction_ITU_R_709_2))
  }

  @Test("LUB-1053: Conversion preserves601 color and retained frames")
  func conversionPreserves601ColorAndRetainedFrames() throws {
    let store = ProgramRenderCameraFrameStore(
      width: 8, height: 12, device: try #require(MTLCreateSystemDefaultDevice()))
    let input = try buffer(
      width: 16, height: 8, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    fill(input, luma: 81, cb: 90, cr: 240)
    CVBufferSetAttachment(
      input, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
    store.copyAndYield(input)
    let first = try #require(try store.wait(timeout: 1))
    let retainedPixels = lumaBytes(first.pixelBuffer)
    for (x, y) in [(0, 0), (7, 0), (0, 11), (7, 11), (4, 6)] {
      let value = Int(firstLuma(first.pixelBuffer, x: x, y: y))
      #expect(abs(value - 54) <= 2, "601→709 scaled luma at (\(x), \(y)) = \(value)")
    }
    #expect(
      CFEqual(
        CVBufferCopyAttachment(input, kCVImageBufferYCbCrMatrixKey, nil),
        kCVImageBufferYCbCrMatrix_ITU_R_601_4))
    // More frames than the old three-buffer ring must not overwrite a lease.
    fill(input, luma: 16)
    for _ in 0..<5 { store.copyAndYield(input) }
    let next = try #require(try store.wait(after: first.serial, timeout: 1))
    #expect(first.serial < next.serial)
    // Lifetime is an exact byte comparison, independent of the color expectation.
    #expect(lumaBytes(first.pixelBuffer) == retainedPixels)
    #expect(firstLuma(next.pixelBuffer) <= 1)
  }

  @Test("LUB-1053: Scaling uses the whole input instead of cropping to canvas")
  func scalingUsesTheWholeInputInsteadOfCroppingToCanvas() throws {
    let store = ProgramRenderCameraFrameStore(
      width: 8, height: 12, device: try #require(MTLCreateSystemDefaultDevice()))
    let input = try buffer(
      width: 16, height: 8, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    fill(input, luma: 16)
    CVPixelBufferLockBaseAddress(input, [])
    let y = CVPixelBufferGetBaseAddressOfPlane(input, 0)!.assumingMemoryBound(to: UInt8.self)
    for row in 0..<8 {
      for column in 8..<16 { y[row * CVPixelBufferGetBytesPerRowOfPlane(input, 0) + column] = 235 }
    }
    CVPixelBufferUnlockBaseAddress(input, [])
    store.copyAndYield(input)
    let output = try #require(try store.wait(timeout: 1)).pixelBuffer
    #expect(firstLuma(output, x: 1, y: 10) <= 1)
    #expect(firstLuma(output, x: 6, y: 10) >= 254)
  }

  @Test("LUB-1053: Conversion failure is reported and next valid frame recovers")
  func conversionFailureIsReportedAndNextValidFrameRecovers() throws {
    let store = ProgramRenderCameraFrameStore(
      width: 8, height: 8, device: try #require(MTLCreateSystemDefaultDevice()))
    let input = try buffer(
      width: 16, height: 16, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      iosurface: false)
    fill(input, luma: 0)
    CVBufferSetAttachment(
      input, kCVImageBufferTransferFunctionKey, "unknown-transfer" as CFString, .shouldPropagate)
    #expect(CVBufferCopyAttachment(input, kCVImageBufferTransferFunctionKey, nil) != nil)
    store.copyAndYield(input)
    #expect(throws: (any Error).self) { try store.wait(timeout: 1) }
    CVBufferRemoveAttachment(input, kCVImageBufferTransferFunctionKey)
    store.copyAndYield(input)
    #expect(try store.wait(timeout: 1) != nil)
  }

  private func buffer(width: Int, height: Int, format: OSType, iosurface: Bool = true) throws
    -> CVPixelBuffer
  {
    var result: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      nil, width, height, format,
      (iosurface
        ? [
          kCVPixelBufferIOSurfacePropertiesKey as String: [:],
          kCVPixelBufferMetalCompatibilityKey as String: true,
        ] as CFDictionary : nil), &result)
    #expect(status == kCVReturnSuccess)
    return try #require(result)
  }
  private func lumaBytes(_ buffer: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    return (0..<CVPixelBufferGetHeightOfPlane(buffer, 0)).flatMap { row in
      Array(
        UnsafeBufferPointer(
          start: base.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)),
          count: CVPixelBufferGetWidthOfPlane(buffer, 0)))
    }
  }

  private func firstLuma(_ buffer: CVPixelBuffer, x: Int = 0, y: Int = 0) -> UInt8 {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    return CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.advanced(
      by: y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + x
    ).load(as: UInt8.self)
  }
  private func fill(_ buffer: CVPixelBuffer, luma: UInt8, cb: UInt8 = 128, cr: UInt8 = 128) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    if CVPixelBufferGetPlaneCount(buffer) == 0 {
      memset(
        CVPixelBufferGetBaseAddress(buffer), 0,
        CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
      return
    }
    memset(
      CVPixelBufferGetBaseAddressOfPlane(buffer, 0), Int32(luma),
      CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * CVPixelBufferGetHeightOfPlane(buffer, 0))
    let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
    for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
      for column in 0..<CVPixelBufferGetWidthOfPlane(buffer, 1) {
        let offset = row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) + column * 2
        uv[offset] = cb
        uv[offset + 1] = cr
      }
    }
  }
}
