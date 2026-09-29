// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgramRuntime
import Testing

@Suite
struct ProgramPairPreviewRegionsUnitTestSuite {
  @Test func regionsKeepEqualHeightsAndLeaveFourPixelGap() {
    for size in [
      CGSize(width: 600, height: 400), CGSize(width: 1200, height: 200),
      CGSize(width: 1, height: 1), .zero,
    ] {
      let regions = ProgramPairPreviewRegions(
        drawable: size,
        landscapeSize: CGSize(width: 1920, height: 1080),
        portraitSize: CGSize(width: 1080, height: 1920))
      #expect(regions.landscape.height == regions.portrait.height)
      #expect(regions.gap.width == min(4, floor(size.width)))
      #expect(regions.landscape.maxX == regions.gap.minX)
      #expect(regions.gap.maxX == regions.portrait.minX)
      for rect in [regions.landscape, regions.gap, regions.portrait] {
        #expect(rect.minX >= 0 && rect.minY >= 0)
        #expect(rect.maxX <= size.width && rect.maxY <= size.height)
      }
      #expect(abs(regions.landscape.width - regions.landscape.height * 16 / 9) < 1)
      #expect(abs(regions.portrait.width - regions.portrait.height * 9 / 16) < 1)
    }
  }
}
