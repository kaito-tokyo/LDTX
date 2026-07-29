// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import LDTXProgram
@testable import LDTXProgramRuntime
import LDTXVideoComposition
@testable import LDTXVideoRendering
import Metal
import Testing

@Suite
struct VideoCompositorTests {
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func diagnosticComponentKindCodesRemainStableWhenRetainedTextureIsAdded() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .b5g6r5Unorm,
            width: 2,
            height: 2,
            mipmapped: false
        )
        let texture = try #require(device.makeTexture(descriptor: descriptor))

        #expect(VideoCompositor.componentKindCode(.testPattern(TestPatternComponent(
            timeSeconds: 0,
            destinationRect: SIMD4<UInt32>(0, 0, 2, 2)
        ))) == 5)
        #expect(VideoCompositor.componentKindCode(.retainedTexture(RetainedTextureComponent(
            colorTexture: texture,
            destinationRect: SIMD4<UInt32>(0, 0, 2, 2)
        ))) == 6)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func retainedTextureRejectsDestinationOutsideOutputBounds() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .b5g6r5Unorm,
            width: 2,
            height: 2,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let compositor = try VideoCompositor(configuration: VideoCompositorConfiguration(
            width: 4,
            height: 4,
            pixelBufferPoolMinimumBufferCount: 1
        ), device: device)

        #expect(throws: VideoCompositorError.self) {
            try compositor.render([
                RetainedTextureComponent(
                    colorTexture: texture,
                    destinationRect: SIMD4<UInt32>(3, 0, 5, 2)
                )
            ])
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func retainedTextureRejectsExplicitlyNonSampleableTexture() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .b5g6r5Unorm,
            width: 2,
            height: 2,
            mipmapped: false
        )
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let compositor = try VideoCompositor(configuration: VideoCompositorConfiguration(
            width: 4,
            height: 4,
            pixelBufferPoolMinimumBufferCount: 1
        ), device: device)

        #expect(throws: VideoCompositorError.self) {
            try compositor.render([
                RetainedTextureComponent(
                    colorTexture: texture,
                    destinationRect: SIMD4<UInt32>(0, 0, 2, 2)
                )
            ])
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func retainedClockTextureCompositesIntoIntegerNV12Planes() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let clockRenderer = try MetalClockOverlayRenderer(device: device)
        let overlay = try clockRenderer.renderClockOverlay(ClockOverlayRenderRequest(
            text: "12:34:56",
            component: ClockComponent(
                foregroundRed: 1,
                foregroundGreen: 0,
                foregroundBlue: 0,
                background: "rgba(255, 0, 0, 0.5)"
            ),
            pixelWidth: 96,
            pixelHeight: 56
        ))
        let compositor = try VideoCompositor(configuration: VideoCompositorConfiguration(
            width: 128,
            height: 72,
            pixelBufferPoolMinimumBufferCount: 3
        ), device: device)

        let output = try compositor.render([
            SolidColorComponent(
                color: SIMD4<Float>(0, 0, 0, 1),
                destinationRect: SIMD4<UInt32>(0, 0, 128, 72)
            ),
            RetainedTextureComponent(
                colorTexture: overlay.colorTexture,
                alphaTexture: overlay.alphaTexture,
                destinationRect: SIMD4<UInt32>(16, 8, 112, 64)
            )
        ])

        // RGB565 is sampled into 8-bit RGB, converted with the compositor's
        // integer full-range coefficients, then blended with R8 alpha. For
        // opaque red at alpha 128 over black this is exactly YCbCr 27/113/192.
        #expect(luma(in: output, x: 16, y: 8) == 27)
        #expect(chroma(in: output, x: 8, y: 4) == SIMD2<UInt8>(113, 192))
        #expect(luma(in: output, x: 8, y: 4) == 0)

        let transparentGlyphs = try clockRenderer.renderClockOverlay(ClockOverlayRenderRequest(
            text: "12:34:56",
            component: ClockComponent(backgroundAlpha: 0),
            pixelWidth: 128,
            pixelHeight: 72
        ))
        #expect(transparentGlyphs.alphaTexture != nil)
        let glyphOutput = try compositor.render([
            RetainedTextureComponent(
                colorTexture: transparentGlyphs.colorTexture,
                alphaTexture: transparentGlyphs.alphaTexture,
                destinationRect: SIMD4<UInt32>(0, 0, 128, 72)
            )
        ])
        let extrema = lumaExtrema(in: glyphOutput)
        #expect(extrema.minimum == 0)
        #expect(extrema.maximum > 220)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func transparentClockChromaUsesPremultipliedGlyphCoverage() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let width = 128
        let height = 72
        let clockRenderer = try MetalClockOverlayRenderer(device: device)
        let overlay = try clockRenderer.renderClockOverlay(ClockOverlayRenderRequest(
            text: "12:34",
            component: ClockComponent(
                foregroundRed: 1,
                foregroundGreen: 0,
                foregroundBlue: 0,
                backgroundAlpha: 0
            ),
            pixelWidth: width,
            pixelHeight: height
        ))
        let alphaTexture = try #require(overlay.alphaTexture)
        let alpha = try readR8Texture(alphaTexture, using: device)
        let compositor = try VideoCompositor(configuration: VideoCompositorConfiguration(
            width: width,
            height: height,
            pixelBufferPoolMinimumBufferCount: 1
        ), device: device)
        let output = try compositor.render([
            RetainedTextureComponent(
                colorTexture: overlay.colorTexture,
                alphaTexture: alphaTexture,
                destinationRect: SIMD4<UInt32>(0, 0, UInt32(width), UInt32(height))
            )
        ])

        var edgeCell: (x: Int, y: Int, alphaSum: Int)?
        for chromaY in 0..<(height / 2) {
            for chromaX in 0..<(width / 2) {
                let samples = [
                    alpha[(chromaY * 2) * width + chromaX * 2],
                    alpha[(chromaY * 2) * width + chromaX * 2 + 1],
                    alpha[(chromaY * 2 + 1) * width + chromaX * 2],
                    alpha[(chromaY * 2 + 1) * width + chromaX * 2 + 1],
                ]
                guard samples.contains(0), samples.contains(where: { $0 > 0 }) else {
                    continue
                }
                edgeCell = (chromaX, chromaY, samples.reduce(0) { $0 + Int($1) })
                break
            }
            if edgeCell != nil { break }
        }

        let selectedEdgeCell = try #require(edgeCell)
        let weight = 4 * 255
        let inverseAlphaSum = weight - selectedEdgeCell.alphaSum
        let expectedCb =
            (99 * selectedEdgeCell.alphaSum + 128 * inverseAlphaSum + weight / 2) / weight
        let expectedCr =
            (255 * selectedEdgeCell.alphaSum + 128 * inverseAlphaSum + weight / 2) / weight
        let expected = SIMD2<UInt8>(UInt8(expectedCb), UInt8(expectedCr))
        #expect(chroma(in: output, x: selectedEdgeCell.x, y: selectedEdgeCell.y) == expected)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func opaqueRetainedTextureBlendsEveryPartialChromaCellAtOddBounds() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let clockRenderer = try MetalClockOverlayRenderer(device: device)
        let overlay = try clockRenderer.renderClockOverlay(ClockOverlayRenderRequest(
            text: "12",
            component: ClockComponent(
                foregroundRed: 1,
                foregroundGreen: 0,
                foregroundBlue: 0,
                background: "#ff0000"
            ),
            pixelWidth: 2,
            pixelHeight: 2
        ))
        #expect(overlay.alphaTexture == nil)
        let compositor = try VideoCompositor(configuration: VideoCompositorConfiguration(
            width: 4,
            height: 4,
            pixelBufferPoolMinimumBufferCount: 1
        ), device: device)

        let output = try compositor.render([
            RetainedTextureComponent(
                colorTexture: overlay.colorTexture,
                destinationRect: SIMD4<UInt32>(1, 1, 3, 3)
            )
        ])

        // Each chroma cell covers one red luma sample and three untouched
        // black samples: ((99,255) + 3 * (128,128) + 2) / 4.
        for y in 0..<2 {
            for x in 0..<2 {
                #expect(chroma(in: output, x: x, y: y) == SIMD2<UInt8>(121, 160))
            }
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func solidColorProducesNV12PixelBuffer() throws {
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

        #expect(CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        #expect(CVPixelBufferGetWidth(output) == 64)
        #expect(CVPixelBufferGetHeight(output) == 48)
        #expect(CVPixelBufferGetPlaneCount(output) == 2)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func fillProgramsProduceSingleComponentNV12PixelBuffer() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())

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

            #expect(components.count == 1)
            #expect(CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            #expect(CVPixelBufferGetWidth(output) == 128)
            #expect(CVPixelBufferGetHeight(output) == 72)
            #expect(CVPixelBufferGetPlaneCount(output) == 2)
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func inputDeviceDestinationChangeReusesPipelineSpecialization() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let compositor = try VideoCompositor(configuration: VideoCompositorConfiguration(
            width: 128,
            height: 72,
            pixelBufferPoolMinimumBufferCount: 3
        ), device: device)
        let source = try makeNV12InputSource(width: 64, height: 36, device: device)

        _ = try compositor.render([
            CameraInputComponent(
                source: source,
                destinationRect: SIMD4<UInt32>(0, 0, 64, 36)
            )
        ])
        #expect(compositor.inputNv12DevicePipelineSpecializationCount == 1)

        let movedOutput = try compositor.render([
            CameraInputComponent(
                source: source,
                destinationRect: SIMD4<UInt32>(32, 18, 96, 54)
            )
        ])
        #expect(compositor.inputNv12DevicePipelineSpecializationCount == 1)
        #expect(luma(in: movedOutput, x: 40, y: 24) > 0)
        #expect(luma(in: movedOutput, x: 8, y: 8) == 0)
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
        try #require(status == kCVReturnSuccess)
        return try #require(pixelBuffer)
    }

    private func makeNV12InputSource(width: Int, height: Int, device: MTLDevice) throws -> MetalVideoSource {
        let pixelBuffer = try makeNV12InputPixelBuffer(width: width, height: height)
        fillLuma(of: pixelBuffer, with: 192)
        var optionalTextureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &optionalTextureCache)
        let textureCache = try #require(optionalTextureCache)
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
            alphaMaskKind: nil,
            contentKind: .captured
        )
    }

    private func readR8Texture(_ texture: MTLTexture, using device: MTLDevice) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        let stagingTexture = try #require(device.makeTexture(descriptor: descriptor))
        let commandQueue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(commandQueue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeBlitCommandEncoder())
        encoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: stagingTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)

        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height)
        stagingTexture.getBytes(
            &bytes,
            bytesPerRow: texture.width,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        return bytes
    }

    private func fillLuma(of pixelBuffer: CVPixelBuffer, with value: UInt8) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            Issue.record("Missing luma plane")
            return
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        for row in 0..<height {
            baseAddress.advanced(by: row * bytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
                .initialize(repeating: value, count: bytesPerRow)
        }
    }

    private func luma(in pixelBuffer: CVPixelBuffer, x: Int, y: Int) -> UInt8 {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            Issue.record("Missing luma plane")
            return 0
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        return baseAddress
            .advanced(by: y * bytesPerRow + x)
            .assumingMemoryBound(to: UInt8.self)
            .pointee
    }

    private func chroma(in pixelBuffer: CVPixelBuffer, x: Int, y: Int) -> SIMD2<UInt8> {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            Issue.record("Missing chroma plane")
            return .zero
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let pixel = baseAddress
            .advanced(by: y * bytesPerRow + x * 2)
            .assumingMemoryBound(to: UInt8.self)
        return SIMD2<UInt8>(pixel[0], pixel[1])
    }

    private func lumaExtrema(in pixelBuffer: CVPixelBuffer) -> (minimum: UInt8, maximum: UInt8) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            Issue.record("Missing luma plane")
            return (0, 0)
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        var minimum = UInt8.max
        var maximum = UInt8.min
        for y in 0..<height {
            let row = baseAddress
                .advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                minimum = min(minimum, row[x])
                maximum = max(maximum, row[x])
            }
        }
        return (minimum, maximum)
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
        try #require(status == kCVReturnSuccess)
        return try #require(metalTexture)
    }
}
