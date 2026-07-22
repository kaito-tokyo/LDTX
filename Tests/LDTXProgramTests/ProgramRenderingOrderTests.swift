// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXProgramRendering
import LDTXVideoComposition
import CoreVideo
import Metal
import simd
import Testing

struct ProgramRenderingOrderTests {
    @Test func compositeRenderingUsesLastVideoComponentAsBottomLayer() throws {
        let composite = CompositeProgramDefinition(steps: [
            CompositeProgramStep(component: .fillSolidColor(FillSolidColorComponent(
                red: 1,
                green: 0,
                blue: 0,
                alpha: 1
            ))),
            CompositeProgramStep(component: .fillSolidColor(FillSolidColorComponent(
                red: 0,
                green: 1,
                blue: 0,
                alpha: 1
            )))
        ])

        let components = composite.components(
            width: 64,
            height: 64,
            source: nil,
            timeSeconds: 0
        )
        let commands = components.map { $0.makeCommand() }

        let first = try #require(commands.first)
        let last = try #require(commands.last)
        guard case let .solidColor(bottom) = first,
              case let .solidColor(top) = last else {
            Issue.record("Expected solid-color commands in rendered order.")
            return
        }

        #expect(bottom.color == SIMD4<Float>(0, 1, 0, 1))
        #expect(top.color == SIMD4<Float>(1, 0, 0, 1))
    }

    @Test func mutedCameraWithoutBackgroundRemovalProducesOpaqueBlack() throws {
        let source = try makeDummySource(hasAlphaMask: false)
        let command = try #require(cameraCommand(source: source))

        guard case let .solidColor(fill) = command else {
            Issue.record("Expected a muted camera to produce a solid-color command.")
            return
        }
        #expect(fill.color == SIMD4<Float>(0, 0, 0, 1))
    }

    @Test func mutedCameraWithBackgroundRemovalProducesTransparentBlack() throws {
        let source = try makeDummySource(hasAlphaMask: true)
        let command = try #require(cameraCommand(source: source))

        guard case let .solidColor(fill) = command else {
            Issue.record("Expected a muted background-removed camera to produce a solid-color command.")
            return
        }
        #expect(fill.color == SIMD4<Float>(0, 0, 0, 0))
    }

    @Test func capturedCameraStillProducesCameraInputCommand() throws {
        let source = try makeSource(contentKind: .captured, hasAlphaMask: false)
        let command = try #require(cameraCommand(source: source))

        guard case .cameraInput = command else {
            Issue.record("Expected an unmuted camera to keep the normal camera-input command.")
            return
        }
    }

    private func cameraCommand(source: MetalVideoSource) -> MetalVideoComponentCommand? {
        var commands: [MetalVideoComponentCommand] = []
        ProgramComponent.inputCameraDevice(InputDeviceComponent()).appendComponentCommands(
            to: &commands,
            worldWidth: 64,
            worldHeight: 64,
            outputWidth: 64,
            outputHeight: 64,
            source: source,
            timeSeconds: 0
        )
        return commands.first
    }

    private func makeDummySource(hasAlphaMask: Bool) throws -> MetalVideoSource {
        try makeSource(contentKind: .dummy, hasAlphaMask: hasAlphaMask)
    }

    private func makeSource(
        contentKind: VideoFrameContentKind,
        hasAlphaMask: Bool
    ) throws -> MetalVideoSource {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        var textureCache: CVMetalTextureCache?
        #expect(CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache) == kCVReturnSuccess)
        let cache = try #require(textureCache)
        var texture: CVMetalTexture?
        #expect(CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            buffer,
            nil,
            .bgra8Unorm,
            16,
            16,
            0,
            &texture
        ) == kCVReturnSuccess)
        let metalTexture = try #require(texture)
        let alphaTexture = hasAlphaMask
            ? device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm,
                width: 16,
                height: 16,
                mipmapped: false
            ))
            : nil
        return .nv12Textures(
            pixelBuffer: buffer,
            lumaMetalTexture: metalTexture,
            chromaMetalTexture: metalTexture,
            alphaTexture: alphaTexture,
            alphaMaskKind: hasAlphaMask ? .oneComponent8 : nil,
            contentKind: contentKind
        )
    }
}
