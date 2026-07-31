// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import LDTXWorkspace
import Testing

@testable import LDTXVision

@Suite("Vision histogram gate")
struct VisionHistogramGateTests {
  @Test("Value histogram accepts the expected dominant bin")
  func valueHistogramAcceptsExpectedPeak() throws {
    let buffer = try pixelBuffer(pixels: [
      (0, 0, 0), (0, 0, 0), (0, 0, 0), (0, 0, 0),
      (0, 0, 0), (0, 0, 0), (255, 255, 255), (255, 255, 255),
    ])
    let gate = WorkspaceVisionHistogramGate(
      channel: .value,
      binCount: 8,
      expectedPeakBin: 0,
      minimumPeakRatio: 0.5
    )

    #expect(VisionHistogramGate.accepts(pixelBuffer: buffer, configuration: gate))
  }

  @Test("Threshold comparison is strict like the reference implementation")
  func thresholdComparisonIsStrict() throws {
    let buffer = try pixelBuffer(pixels: [
      (0, 0, 0), (0, 0, 0), (0, 0, 0), (0, 0, 0),
      (255, 255, 255), (255, 255, 255), (255, 255, 255), (255, 255, 255),
    ])
    let gate = WorkspaceVisionHistogramGate(
      channel: .value,
      binCount: 8,
      expectedPeakBin: 0,
      minimumPeakRatio: 0.5
    )

    #expect(!VisionHistogramGate.accepts(pixelBuffer: buffer, configuration: gate))
  }

  @Test("Hue uses the OpenCV half-degree range")
  func hueUsesOpenCVRange() throws {
    let buffer = try pixelBuffer(pixels: Array(repeating: (0, 255, 0), count: 8))
    // Green is 120 degrees, represented as 60 in OpenCV's [0, 180) hue range.
    let gate = WorkspaceVisionHistogramGate(
      channel: .hue,
      binCount: 18,
      expectedPeakBin: 6,
      minimumPeakRatio: 0.9
    )

    #expect(VisionHistogramGate.accepts(pixelBuffer: buffer, configuration: gate))
  }

  @Test("Hue is quantized to an OpenCV 8-bit HSV value before binning")
  func hueUsesOpenCVIntegerQuantization() throws {
    let buffer = try pixelBuffer(pixels: Array(repeating: (255, 5, 0), count: 8))
    let gate = WorkspaceVisionHistogramGate(
      channel: .hue,
      binCount: 180,
      expectedPeakBin: 1,
      minimumPeakRatio: 0.9
    )

    #expect(VisionHistogramGate.accepts(pixelBuffer: buffer, configuration: gate))
  }

  @Test("Only pixels inside the normalized region contribute")
  func normalizedRegionLimitsHistogram() throws {
    let buffer = try pixelBuffer(pixels: [
      (0, 0, 0), (0, 0, 0), (0, 0, 0), (0, 0, 0),
      (0, 0, 0), (0, 0, 0), (0, 0, 0), (0, 0, 0),
      (255, 255, 255), (255, 255, 255), (255, 255, 255), (255, 255, 255),
      (255, 255, 255), (255, 255, 255), (255, 255, 255), (255, 255, 255),
    ])
    let gate = WorkspaceVisionHistogramGate(
      channel: .value,
      binCount: 8,
      expectedPeakBin: 7,
      minimumPeakRatio: 0.9,
      region: .init(x: 0.5, y: 0, width: 0.5, height: 1)
    )

    #expect(VisionHistogramGate.accepts(pixelBuffer: buffer, configuration: gate))
  }

  @Test("A non-finite region closes the gate instead of converting NaN to Int")
  func nonFiniteRegionClosesGate() throws {
    let buffer = try pixelBuffer(pixels: Array(repeating: (0, 0, 0), count: 8))
    var gate = WorkspaceVisionHistogramGate()
    gate.region.x = .nan

    #expect(!VisionHistogramGate.accepts(pixelBuffer: buffer, configuration: gate))
  }

  @Test("A zero-area region expands to eight pixels")
  func zeroAreaRegionExpandsToMinimumSize() throws {
    let buffer = try pixelBuffer(pixels: Array(repeating: (0, 0, 0), count: 16))
    let gate = WorkspaceVisionHistogramGate(
      channel: .value,
      binCount: 8,
      expectedPeakBin: 0,
      minimumPeakRatio: 0,
      region: .init(x: 0.5, y: 0, width: 0, height: 1)
    )

    #expect(VisionHistogramGate.accepts(pixelBuffer: buffer, configuration: gate))
  }

  @Test("Small regions expand within image bounds at either edge")
  func smallRegionsExpandWithinImageBounds() throws {
    let buffer = try pixelBuffer(
      pixels: Array(repeating: (0, 0, 0), count: 16), height: 16)
    let leadingGate = WorkspaceVisionHistogramGate(
      minimumPeakRatio: 0.9,
      region: .init(x: 0, y: 0, width: 0.01, height: 0.01)
    )
    let trailingGate = WorkspaceVisionHistogramGate(
      minimumPeakRatio: 0.9,
      region: .init(x: 0.99, y: 0.99, width: 0.01, height: 0.01)
    )

    #expect(VisionHistogramGate.accepts(pixelBuffer: buffer, configuration: leadingGate))
    #expect(VisionHistogramGate.accepts(pixelBuffer: buffer, configuration: trailingGate))
  }

  @Test("Inputs smaller than eight pixels are edge-padded before thresholding")
  func smallInputsAreEdgePadded() throws {
    let horizontalPixels: [(UInt8, UInt8, UInt8)] = [
      (0, 0, 0), (0, 0, 0), (0, 0, 0), (0, 0, 0),
      (255, 255, 255), (255, 255, 255), (255, 255, 255),
    ]
    let sevenWide = try pixelBuffer(pixels: horizontalPixels, height: 8)
    let blackRow = Array(repeating: (UInt8(0), UInt8(0), UInt8(0)), count: 8)
    let whiteRow = Array(repeating: (UInt8(255), UInt8(255), UInt8(255)), count: 8)
    let sevenHigh = try pixelBuffer(
      rows: Array(repeating: blackRow, count: 4) + Array(repeating: whiteRow, count: 3)
    )
    let gate = WorkspaceVisionHistogramGate(
      channel: .value,
      binCount: 8,
      expectedPeakBin: 0,
      minimumPeakRatio: 0.5
    )

    // Padding repeats the final white column or row, leaving black at exactly
    // half of the 8x8 samples. The reference comparison is strict, so both close.
    #expect(!VisionHistogramGate.accepts(pixelBuffer: sevenWide, configuration: gate))
    #expect(!VisionHistogramGate.accepts(pixelBuffer: sevenHigh, configuration: gate))
  }

  @Test("A cancellation request closes the gate")
  func cancellationClosesGate() throws {
    let buffer = try pixelBuffer(
      pixels: Array(repeating: (0, 0, 0), count: 8), height: 8)

    let accepted = VisionHistogramGate.accepts(
      pixelBuffer: buffer,
      configuration: .init(minimumPeakRatio: 0),
      isCancellationRequested: { true }
    )
    #expect(!accepted)
  }

  private func pixelBuffer(
    pixels: [(UInt8, UInt8, UInt8)],
    height: Int = 8
  ) throws -> CVPixelBuffer {
    try pixelBuffer(rows: Array(repeating: pixels, count: height))
  }

  private func pixelBuffer(
    rows: [[(UInt8, UInt8, UInt8)]]
  ) throws -> CVPixelBuffer {
    guard let width = rows.first?.count, width > 0, rows.allSatisfy({ $0.count == width }) else {
      throw TestError.invalidPixels
    }
    var buffer: CVPixelBuffer?
    let attributes: CFDictionary =
      [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
      ] as CFDictionary
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      rows.count,
      kCVPixelFormatType_32BGRA,
      attributes,
      &buffer
    )
    guard status == kCVReturnSuccess, let buffer else {
      throw TestError.pixelBufferCreationFailed(status)
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let baseAddress = CVPixelBufferGetBaseAddress(buffer)!
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    for (y, pixels) in rows.enumerated() {
      let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
      for (index, pixel) in pixels.enumerated() {
        row[index * 4] = pixel.2
        row[index * 4 + 1] = pixel.1
        row[index * 4 + 2] = pixel.0
        row[index * 4 + 3] = 255
      }
    }
    return buffer
  }

  private enum TestError: Error {
    case invalidPixels
    case pixelBufferCreationFailed(CVReturn)
  }
}
