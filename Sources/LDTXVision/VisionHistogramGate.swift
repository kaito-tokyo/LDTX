// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import LDTXWorkspace

/// CPU-only HSV peak-histogram gate compatible with the HistClassifier
/// calculation used by obs-pokemon-sv-screen-builder.
public enum VisionHistogramGate {
  public static let minimumRegionDimension = 8
  private static let hsvShift = 12
  private static let hsvRounding = 1 << (hsvShift - 1)
  private static let saturationDivisionTable = divisionTable(numerator: 255)
  private static let hueDivisionTable = divisionTable(numerator: 180, denominatorScale: 6)

  public static func accepts(
    pixelBuffer: CVPixelBuffer,
    configuration: WorkspaceVisionHistogramGate,
    isCancellationRequested: @Sendable () -> Bool = { false }
  ) -> Bool {
    guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
      return false
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    guard width > 0, height > 0 else { return false }
    guard configuration.region.x.isFinite,
      configuration.region.y.isFinite,
      configuration.region.width.isFinite,
      configuration.region.height.isFinite
    else {
      return false
    }
    let region = WorkspaceVisionHistogramRegion(
      x: configuration.region.x,
      y: configuration.region.y,
      width: configuration.region.width,
      height: configuration.region.height
    )
    let requestedMinimumX = min(Int((region.x * Double(width)).rounded(.down)), width)
    let requestedMinimumY = min(Int((region.y * Double(height)).rounded(.down)), height)
    let requestedMaximumX = min(
      Int(((region.x + region.width) * Double(width)).rounded(.up)), width)
    let requestedMaximumY = min(
      Int(((region.y + region.height) * Double(height)).rounded(.up)), height)
    let xRange = expandedRange(
      minimum: requestedMinimumX, maximum: requestedMaximumX, limit: width)
    let yRange = expandedRange(
      minimum: requestedMinimumY, maximum: requestedMaximumY, limit: height)
    guard !xRange.isEmpty, !yRange.isEmpty else { return false }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let binCount = min(max(configuration.binCount, 1), 256)
    var histogram = [Int](repeating: 0, count: binCount)

    let sampleWidth = max(xRange.count, minimumRegionDimension)
    let sampleHeight = max(yRange.count, minimumRegionDimension)
    for sampleY in 0..<sampleHeight {
      guard !isCancellationRequested() else { return false }
      let y = yRange.lowerBound + min(sampleY, yRange.count - 1)
      let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
      for sampleX in 0..<sampleWidth {
        let x = xRange.lowerBound + min(sampleX, xRange.count - 1)
        let pixel = row.advanced(by: x * 4)
        let blue = Int(pixel[0])
        let green = Int(pixel[1])
        let red = Int(pixel[2])
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum

        let value: Int
        let range: Int
        switch configuration.channel {
        case .hue:
          var hue = 0
          if delta > 0 {
            if maximum == red {
              hue = green - blue
            } else if maximum == green {
              hue = blue - red + 2 * delta
            } else {
              hue = red - green + 4 * delta
            }
            hue = descale(hue * hueDivisionTable[delta])
            if hue < 0 { hue += 180 }
          }
          value = hue
          range = 180
        case .saturation:
          value = maximum == 0 ? 0 : descale(delta * saturationDivisionTable[maximum])
          range = 256
        case .value:
          value = maximum
          range = 256
        }
        let index = min(value * binCount / range, binCount - 1)
        histogram[index] += 1
      }
    }

    var peakIndex = 0
    for index in 1..<histogram.count where histogram[index] > histogram[peakIndex] {
      peakIndex = index
    }
    let pixelCount = sampleWidth * sampleHeight
    let requiredCount = Double(pixelCount) * min(max(configuration.minimumPeakRatio, 0), 1)
    return peakIndex == min(max(configuration.expectedPeakBin, 0), binCount - 1)
      && Double(histogram[peakIndex]) > requiredCount
  }

  private static func expandedRange(
    minimum: Int,
    maximum: Int,
    limit: Int
  ) -> Range<Int> {
    let requiredCount = minimumRegionDimension
    var lowerBound = minimum
    var upperBound = maximum
    let missingCount = max(requiredCount - (upperBound - lowerBound), 0)
    let appendedCount = min(missingCount, limit - upperBound)
    upperBound += appendedCount
    lowerBound = max(lowerBound - (missingCount - appendedCount), 0)
    return lowerBound..<upperBound
  }

  private static func descale(_ value: Int) -> Int {
    (value + hsvRounding) >> hsvShift
  }

  private static func divisionTable(
    numerator: Int,
    denominatorScale: Int = 1
  ) -> [Int] {
    var table = [Int](repeating: 0, count: 256)
    for value in 1..<table.count {
      table[value] = Int(
        (Double(numerator << hsvShift) / Double(denominatorScale * value))
          .rounded(.toNearestOrEven)
      )
    }
    return table
  }
}
