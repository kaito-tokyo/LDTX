// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import CoreVideo
import LDTXVision
import Testing

@Suite
struct VisionFramePoolEasyTests {
  @Test func ocrCopyUsesConfiguredSubsamplingAndOneSlot() throws {
    let copier = VisionOCRFrameCopier()
    let image = CIImage(color: .white)
      .cropped(to: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))

    var first = copier.copy(image: image, subsamplingRate: 2)
    #expect(CVPixelBufferGetWidth(try #require(first).pixelBuffer) == 960)
    #expect(CVPixelBufferGetHeight(try #require(first).pixelBuffer) == 540)
    #expect(copier.copy(image: image, subsamplingRate: 1) == nil)

    first = nil
    let second = try #require(copier.copy(image: image, subsamplingRate: 4))
    #expect(CVPixelBufferGetWidth(second.pixelBuffer) == 480)
    #expect(CVPixelBufferGetHeight(second.pixelBuffer) == 270)
  }
}
