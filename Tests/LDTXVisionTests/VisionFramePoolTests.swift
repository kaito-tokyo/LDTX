// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import CoreVideo
import LDTXVision
import Testing

struct VisionFramePoolTests {
    @Test func copiesIntoFixedBGRAEnvelopeAndReusesBuffer() throws {
        let pool = VisionFramePool(capacity: 1)
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        var first = pool.copy(image: image)
        let firstBuffer = try #require(first).pixelBuffer

        #expect(CVPixelBufferGetWidth(firstBuffer) == 512)
        #expect(CVPixelBufferGetHeight(firstBuffer) == 288)
        #expect(CVPixelBufferGetPixelFormatType(firstBuffer) == kCVPixelFormatType_32BGRA)
        #expect(pool.copy(image: image) == nil)

        first = nil
        let second = try #require(pool.copy(image: image))
        #expect(firstBuffer === second.pixelBuffer)
    }
}
