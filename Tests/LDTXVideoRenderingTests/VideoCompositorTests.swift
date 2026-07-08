// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import LDTXVideoComposition
import LDTXVideoRendering
import Metal
import XCTest

final class VideoCompositorTests: XCTestCase {
    func testSolidColorProducesNV12PixelBuffer() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is not available.")
        }

        let compositor = try VideoCompositor(configuration: VideoCompositorConfiguration(
            width: 64,
            height: 48,
            pixelBufferPoolMinimumBufferCount: 3
        ))
        let output = try compositor.render([
            SolidColorComponent(
                color: SIMD4<Float>(1, 0, 0, 1),
                destinationRect: SIMD4<UInt32>(0, 0, 64, 48)
            )
        ])

        XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        XCTAssertEqual(CVPixelBufferGetWidth(output), 64)
        XCTAssertEqual(CVPixelBufferGetHeight(output), 48)
        XCTAssertEqual(CVPixelBufferGetPlaneCount(output), 2)
    }

    func testFillProgramsProduceSingleComponentNV12PixelBuffer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is not available.")
        }

        let compositor = try VideoCompositor(configuration: VideoCompositorConfiguration(
            width: 128,
            height: 72,
            pixelBufferPoolMinimumBufferCount: 3
        ), device: device)
        let programs: [[any MetalVideoComponent]] = [
            MetalVideoComponentPrograms.fillSolidColor(width: 128, height: 72),
            MetalVideoComponentPrograms.fillLinearGradient(width: 128, height: 72),
            MetalVideoComponentPrograms.fillRadialGradient(width: 128, height: 72),
            MetalVideoComponentPrograms.fillConicGradient(width: 128, height: 72),
            MetalVideoComponentPrograms.inputCameraDevice(
                width: 128,
                height: 72,
                source: try makeNV12InputSource(
                    width: 128,
                    height: 72,
                    device: device
                )
            ),
            MetalVideoComponentPrograms.testPattern(width: 128, height: 72, timeSeconds: 1.25)
        ]

        for components in programs {
            let output = try compositor.render(components)

            XCTAssertEqual(components.count, 1)
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            XCTAssertEqual(CVPixelBufferGetWidth(output), 128)
            XCTAssertEqual(CVPixelBufferGetHeight(output), 72)
            XCTAssertEqual(CVPixelBufferGetPlaneCount(output), 2)
        }
    }

    private func makeNV12InputPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw XCTSkip("Could not create NV12 input pixel buffer.")
        }
        return pixelBuffer
    }

    private func makeNV12InputSource(width: Int, height: Int, device: MTLDevice) throws -> MetalVideoSource {
        let pixelBuffer = try makeNV12InputPixelBuffer(width: width, height: height)
        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        guard let textureCache else {
            throw XCTSkip("Could not create texture cache.")
        }
        let lumaMetalTexture = try makeTexture(
            pixelBuffer,
            textureCache: textureCache,
            pixelFormat: .r8Uint,
            width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
            height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
            planeIndex: 0
        )
        let chromaMetalTexture = try makeTexture(
            pixelBuffer,
            textureCache: textureCache,
            pixelFormat: .rg8Uint,
            width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
            height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
            planeIndex: 1
        )
        return .nv12Textures(
            pixelBuffer: pixelBuffer,
            lumaMetalTexture: lumaMetalTexture,
            chromaMetalTexture: chromaMetalTexture,
            alphaTexture: nil,
            alphaMaskKind: nil
        )
    }

    private func makeTexture(
        _ pixelBuffer: CVPixelBuffer,
        textureCache: CVMetalTextureCache,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        planeIndex: Int
    ) throws -> CVMetalTexture {
        var metalTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &metalTexture
        )
        guard status == kCVReturnSuccess, let metalTexture else {
            throw XCTSkip("Could not create input texture.")
        }
        return metalTexture
    }
}
