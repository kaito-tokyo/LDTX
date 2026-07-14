// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import CoreVideo
import LDTXVision
import XCTest

final class VisionFramePoolTests: XCTestCase {
    func testCopiesIntoFixedBGRAEnvelopeAndReusesBuffer() throws {
        let pool = VisionFramePool(capacity: 1)
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        var first: VisionFrameSnapshot? = try XCTUnwrap(pool.copy(image: image))
        let firstBuffer = first!.pixelBuffer

        XCTAssertEqual(CVPixelBufferGetWidth(firstBuffer), 512)
        XCTAssertEqual(CVPixelBufferGetHeight(firstBuffer), 288)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(firstBuffer), kCVPixelFormatType_32BGRA)
        XCTAssertNil(pool.copy(image: image))

        first = nil
        let second = try XCTUnwrap(pool.copy(image: image))
        XCTAssertTrue(firstBuffer === second.pixelBuffer)
    }
}
