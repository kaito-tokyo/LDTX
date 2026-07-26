// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import LDTXVideoComposition
import Metal
import OSLog
import simd

public struct VideoCompositorConfiguration: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixelBufferPoolMinimumBufferCount: Int

    public init(width: Int, height: Int, pixelBufferPoolMinimumBufferCount: Int = 24) {
        self.width = width
        self.height = height
        self.pixelBufferPoolMinimumBufferCount = pixelBufferPoolMinimumBufferCount
    }
}

public enum VideoCompositorError: Error, LocalizedError {
    case metalDeviceUnavailable
    case invalidConfiguration
    case shaderCompilationFailed(String)
    case pixelBufferPoolCreationFailed(CVReturn)
    case pixelBufferPoolPrewarmFailed(CVReturn)
    case outputPixelBufferCreationFailed(CVReturn)
    case unsupportedPixelBufferFormat(OSType)
    case textureCreationFailed(CVReturn)
    case commandBufferCreationFailed
    case commandEncoderCreationFailed
    case renderFailed

    public var errorDescription: String? {
        switch self {
        case .metalDeviceUnavailable:
            "Metal is not available on this device."
        case .invalidConfiguration:
            "The Metal video compositor configuration is invalid."
        case let .shaderCompilationFailed(message):
            "The Metal video compositor shader could not be compiled: \(message)"
        case let .pixelBufferPoolCreationFailed(status):
            "CVPixelBufferPoolCreate failed with status \(status)."
        case let .pixelBufferPoolPrewarmFailed(status):
            "CVPixelBufferPool prewarm failed with status \(status)."
        case let .outputPixelBufferCreationFailed(status):
            "CVPixelBufferPoolCreatePixelBuffer failed with status \(status)."
        case let .unsupportedPixelBufferFormat(pixelFormat):
            "The pixel buffer format is unsupported: \(Self.fourCC(pixelFormat))."
        case let .textureCreationFailed(status):
            "CVMetalTextureCacheCreateTextureFromImage failed with status \(status)."
        case .commandBufferCreationFailed:
            "The Metal command buffer could not be created."
        case .commandEncoderCreationFailed:
            "The Metal compute command encoder could not be created."
        case .renderFailed:
            "The Metal command buffer failed."
        }
    }

    private static func fourCC(_ value: OSType) -> String {
        let scalars = [
            UnicodeScalar((value >> 24) & 0xff),
            UnicodeScalar((value >> 16) & 0xff),
            UnicodeScalar((value >> 8) & 0xff),
            UnicodeScalar(value & 0xff)
        ]
        let string = scalars.compactMap { $0 }.map(String.init).joined()
        return string.isEmpty ? "\(value)" : "\(string)(\(value))"
    }
}

public final class VideoCompositor: @unchecked Sendable {
    private enum SourceRange: UInt32 {
        case video = 1
        case full = 2
    }

    private enum SolidColorArgumentIndex {
        static let offsetXY = 2
        static let luma0 = 6
        static let chroma0 = 6
        static let alpha0 = 12
    }

    private enum InputNv12DeviceArgumentIndex {
        static let offsetXY = 2
    }

    private enum LinearGradientArgumentIndex {
        static let offsetXY = 2
        static let luma0 = 6
        static let alpha0 = 7
        static let luma1 = 8
        static let alpha1 = 9
        static let chroma0 = 6
        static let chroma1 = 8
        static let pointUV0 = 10
        static let axisUV = 11
    }

    private enum RadialGradientArgumentIndex {
        static let offsetXY = 2
        static let luma0 = 6
        static let alpha0 = 7
        static let luma1 = 8
        static let alpha1 = 9
        static let chroma0 = 6
        static let chroma1 = 8
        static let centerUV = 10
        static let radiusUV = 11
    }

    private enum ConicGradientArgumentIndex {
        static let offsetXY = 2
        static let luma0 = 6
        static let alpha0 = 7
        static let luma1 = 8
        static let alpha1 = 9
        static let chroma0 = 6
        static let chroma1 = 8
        static let centerUV = 10
        static let startAngleRadians = 11
    }

    private enum TestPatternArgumentIndex {
        static let offsetXY = 2
        static let timeSeconds = 10
    }

    public let configuration: VideoCompositorConfiguration
    public let device: MTLDevice

    private let shaderRegistry: CompositorShaderRegistry

    /// Number of input-device pipeline specializations currently retained by this compositor.
    ///
    /// Destination placement is deliberately excluded: it is a per-command buffer
    /// argument and must not create a new Metal pipeline specialization.
    var inputNv12DevicePipelineSpecializationCount: Int {
        shaderRegistry.inputNv12DevicePipelineSpecializationCount
    }
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let clearLumaPipeline: MTLComputePipelineState
    private let clearChromaPipeline: MTLComputePipelineState
    private let solidColorLumaPipeline: MTLComputePipelineState
    private let solidColorLumaAlphaPipeline: MTLComputePipelineState
    private let solidColorChromaPipeline: MTLComputePipelineState
    private let solidColorChromaAlphaPipeline: MTLComputePipelineState
    private let linearGradientLumaPipeline: MTLComputePipelineState
    private let linearGradientChromaPipeline: MTLComputePipelineState
    private let radialGradientLumaPipeline: MTLComputePipelineState
    private let radialGradientChromaPipeline: MTLComputePipelineState
    private let conicGradientLumaPipeline: MTLComputePipelineState
    private let conicGradientChromaPipeline: MTLComputePipelineState
    private let testPatternLumaPipeline: MTLComputePipelineState
    private let testPatternChromaPipeline: MTLComputePipelineState
    private let outputCanvasResourceManager: OutputCanvasResourceManager
    private let outputPixelBufferRequest: OutputCanvasResourceManager.PixelBufferRequest
    private var outputTextureCache: [UnsafeRawPointer: OutputTexturePair] = [:]
    private var outputTextureCacheOrder: [UnsafeRawPointer] = []

    public init(
        configuration: VideoCompositorConfiguration,
        outputCanvasResourceManager: OutputCanvasResourceManager? = nil,
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) throws {
        guard configuration.width > 0,
              configuration.height > 0,
              configuration.pixelBufferPoolMinimumBufferCount > 0 else {
            throw VideoCompositorError.invalidConfiguration
        }

        guard let device,
              let commandQueue = device.makeCommandQueue() else {
            throw VideoCompositorError.metalDeviceUnavailable
        }

        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        guard let textureCache else {
            throw VideoCompositorError.metalDeviceUnavailable
        }

        self.configuration = configuration
        self.outputCanvasResourceManager = outputCanvasResourceManager ?? OutputCanvasResourceManager(
            minimumBufferCount: configuration.pixelBufferPoolMinimumBufferCount
        )
        self.device = device
        self.commandQueue = commandQueue
        self.textureCache = textureCache
        outputPixelBufferRequest = OutputCanvasResourceManager.PixelBufferRequest(
            width: configuration.width,
            height: configuration.height,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )

        do {
            let library = try Self.makeShaderLibrary(device: device)
            shaderRegistry = CompositorShaderRegistry(device: device, library: library)
            guard let clearLuma = library.makeFunction(name: "clearLumaKernel"),
                  let clearChroma = library.makeFunction(name: "clearChromaKernel"),
                  let solidColorLuma = library.makeFunction(name: "solidColorLumaKernel"),
                  let solidColorLumaAlpha = library.makeFunction(name: "solidColorLumaAlphaKernel"),
                  let solidColorChroma = library.makeFunction(name: "solidColorChromaKernel"),
                  let solidColorChromaAlpha = library.makeFunction(name: "solidColorChromaAlphaKernel"),
                  let linearGradientLuma = library.makeFunction(name: "linearGradientLumaKernel"),
                  let linearGradientChroma = library.makeFunction(name: "linearGradientChromaKernel"),
                  let radialGradientLuma = library.makeFunction(name: "radialGradientLumaKernel"),
                  let radialGradientChroma = library.makeFunction(name: "radialGradientChromaKernel"),
                  let conicGradientLuma = library.makeFunction(name: "conicGradientLumaKernel"),
                  let conicGradientChroma = library.makeFunction(name: "conicGradientChromaKernel"),
                  let testPatternLuma = library.makeFunction(name: "testPatternLumaKernel"),
                  let testPatternChroma = library.makeFunction(name: "testPatternChromaKernel") else {
                throw VideoCompositorError.shaderCompilationFailed("Required kernel functions were not found.")
            }
            clearLumaPipeline = try device.makeComputePipelineState(function: clearLuma)
            clearChromaPipeline = try device.makeComputePipelineState(function: clearChroma)
            solidColorLumaPipeline = try device.makeComputePipelineState(function: solidColorLuma)
            solidColorLumaAlphaPipeline = try device.makeComputePipelineState(function: solidColorLumaAlpha)
            solidColorChromaPipeline = try device.makeComputePipelineState(function: solidColorChroma)
            solidColorChromaAlphaPipeline = try device.makeComputePipelineState(function: solidColorChromaAlpha)
            linearGradientLumaPipeline = try device.makeComputePipelineState(function: linearGradientLuma)
            linearGradientChromaPipeline = try device.makeComputePipelineState(function: linearGradientChroma)
            radialGradientLumaPipeline = try device.makeComputePipelineState(function: radialGradientLuma)
            radialGradientChromaPipeline = try device.makeComputePipelineState(function: radialGradientChroma)
            conicGradientLumaPipeline = try device.makeComputePipelineState(function: conicGradientLuma)
            conicGradientChromaPipeline = try device.makeComputePipelineState(function: conicGradientChroma)
            testPatternLumaPipeline = try device.makeComputePipelineState(function: testPatternLuma)
            testPatternChromaPipeline = try device.makeComputePipelineState(function: testPatternChroma)
        } catch let error as VideoCompositorError {
            throw error
        } catch {
            throw VideoCompositorError.shaderCompilationFailed(error.localizedDescription)
        }
    }

    public func render(_ components: [any MetalVideoComponent]) throws -> CVPixelBuffer {
        try renderCommands(components.map { $0.makeCommand() })
    }

    public func render(_ components: [any MetalVideoComponent], into outputPixelBuffer: CVPixelBuffer) throws {
        try renderCommands(components.map { $0.makeCommand() }, into: outputPixelBuffer)
    }

    public func renderCommands(_ components: [MetalVideoComponentCommand]) throws -> CVPixelBuffer {
        let outputPixelBuffer = try makeOutputPixelBuffer()
        try renderCommands(components, into: outputPixelBuffer, reusingOutputTextures: false)
        return outputPixelBuffer
    }

    public func renderCommands(_ components: [MetalVideoComponentCommand], into outputPixelBuffer: CVPixelBuffer) throws {
        try renderCommands(components, into: outputPixelBuffer, reusingOutputTextures: true)
    }

    private func renderCommands(
        _ components: [MetalVideoComponentCommand],
        into outputPixelBuffer: CVPixelBuffer,
        reusingOutputTextures: Bool
    ) throws {
        guard CVPixelBufferGetWidth(outputPixelBuffer) == configuration.width,
              CVPixelBufferGetHeight(outputPixelBuffer) == configuration.height,
              CVPixelBufferGetPixelFormatType(outputPixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            Self.logger.error(
                "Invalid output pixel buffer expectedWidth=\(self.configuration.width, privacy: .public) expectedHeight=\(self.configuration.height, privacy: .public) expectedPixelFormat=\(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, privacy: .public) actualWidth=\(CVPixelBufferGetWidth(outputPixelBuffer), privacy: .public) actualHeight=\(CVPixelBufferGetHeight(outputPixelBuffer), privacy: .public) actualPixelFormat=\(CVPixelBufferGetPixelFormatType(outputPixelBuffer), privacy: .public) componentCount=\(components.count, privacy: .public)"
            )
            throw VideoCompositorError.invalidConfiguration
        }

        let outputTextures = try outputTextures(for: outputPixelBuffer, reusingOutputTextures: reusingOutputTextures)
        let outputLuma = outputTextures.luma
        let outputChroma = outputTextures.chroma

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            Self.logger.error("Command buffer creation failed")
            throw VideoCompositorError.commandBufferCreationFailed
        }

        guard let clearEncoder = commandBuffer.makeComputeCommandEncoder() else {
            Self.logger.error("Clear command encoder creation failed")
            throw VideoCompositorError.commandEncoderCreationFailed
        }
        bindOutput(outputY: outputLuma, outputUV: outputChroma, to: clearEncoder)
        clearEncoder.setComputePipelineState(clearLumaPipeline)
        dispatch(encoder: clearEncoder, pipeline: clearLumaPipeline, width: configuration.width, height: configuration.height)
        clearEncoder.setComputePipelineState(clearChromaPipeline)
        dispatch(encoder: clearEncoder, pipeline: clearChromaPipeline, width: configuration.width / 2, height: configuration.height / 2)
        clearEncoder.endEncoding()

        for component in components {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                Self.logger.error(
                    "Component command encoder creation failed componentKind=\(Self.componentKindCode(component), privacy: .public)"
                )
                throw VideoCompositorError.commandEncoderCreationFailed
            }

            do {
                switch component {
                case let .solidColor(component):
                let yuvColor = Self.fullRangeYUVColor(from: component.color)
                let bounds = component.destinationRect
                var offsetXY = SIMD2<UInt32>(bounds.x, bounds.y)
                let yWidth = Int(bounds.z - bounds.x)
                let yHeight = Int(bounds.w - bounds.y)
                let chromaX0 = (bounds.x + 1) / 2
                let chromaY0 = (bounds.y + 1) / 2
                let chromaX1 = (bounds.z + 1) / 2
                let chromaY1 = (bounds.w + 1) / 2
                var chromaOffsetXY = SIMD2<UInt32>(chromaX0, chromaY0)
                let chromaWidth = Int(chromaX1 - chromaX0)
                let chromaHeight = Int(chromaY1 - chromaY0)
                var luma0 = Self.uint8StorageValue(fromUnit: yuvColor.x)
                var chroma0 = SIMD2<UInt32>(
                    Self.uint8StorageValue(fromUnit: yuvColor.y),
                    Self.uint8StorageValue(fromUnit: yuvColor.z)
                )
                var alpha0 = Self.uint8StorageValue(fromUnit: yuvColor.w * component.opacity)
                bindOutput(outputY: outputLuma, outputUV: outputChroma, to: encoder)
                if yWidth > 0 && yHeight > 0 {
                    let pipeline = alpha0 == 255 ? solidColorLumaPipeline : solidColorLumaAlphaPipeline
                    encoder.setComputePipelineState(pipeline)
                    encoder.setBytes(&offsetXY, length: MemoryLayout<SIMD2<UInt32>>.stride, index: SolidColorArgumentIndex.offsetXY)
                    encoder.setBytes(&luma0, length: MemoryLayout<UInt32>.stride, index: SolidColorArgumentIndex.luma0)
                    if alpha0 != 255 {
                        encoder.setBytes(&alpha0, length: MemoryLayout<UInt32>.stride, index: SolidColorArgumentIndex.alpha0)
                    }
                    dispatch(encoder: encoder, pipeline: pipeline, width: yWidth, height: yHeight)
                }
                if chromaWidth > 0 && chromaHeight > 0 {
                    let pipeline = alpha0 == 255 ? solidColorChromaPipeline : solidColorChromaAlphaPipeline
                    encoder.setComputePipelineState(pipeline)
                    encoder.setBytes(&chromaOffsetXY, length: MemoryLayout<SIMD2<UInt32>>.stride, index: SolidColorArgumentIndex.offsetXY)
                    encoder.setBytes(&chroma0, length: MemoryLayout<SIMD2<UInt32>>.stride, index: SolidColorArgumentIndex.chroma0)
                    if alpha0 != 255 {
                        encoder.setBytes(&alpha0, length: MemoryLayout<UInt32>.stride, index: SolidColorArgumentIndex.alpha0)
                    }
                    dispatch(encoder: encoder, pipeline: pipeline, width: chromaWidth, height: chromaHeight)
                }
                case let .linearGradient(component):
                let startYUVColor = Self.fullRangeYUVColor(from: component.startColor)
                let endYUVColor = Self.fullRangeYUVColor(from: component.endColor)
                let bounds = component.destinationRect
                var offsetXY = SIMD2<UInt32>(bounds.x, bounds.y)
                let yWidth = Int(bounds.z - bounds.x)
                let yHeight = Int(bounds.w - bounds.y)
                let chromaX0 = (bounds.x + 1) / 2
                let chromaY0 = (bounds.y + 1) / 2
                let chromaX1 = (bounds.z + 1) / 2
                let chromaY1 = (bounds.w + 1) / 2
                var chromaOffsetXY = SIMD2<UInt32>(chromaX0, chromaY0)
                let chromaWidth = Int(chromaX1 - chromaX0)
                let chromaHeight = Int(chromaY1 - chromaY0)
                var luma0 = Float16(startYUVColor.x)
                var luma1 = Float16(endYUVColor.x)
                var chroma0 = SIMD2<Float16>(Float16(startYUVColor.y), Float16(startYUVColor.z))
                var chroma1 = SIMD2<Float16>(Float16(endYUVColor.y), Float16(endYUVColor.z))
                var alpha0 = Float16(startYUVColor.w)
                var alpha1 = Float16(endYUVColor.w)
                var pointUV0 = component.start
                var axisUV = component.end - component.start
                bindOutput(outputY: outputLuma, outputUV: outputChroma, to: encoder)
                encoder.setBytes(&pointUV0, length: MemoryLayout<SIMD2<Float>>.stride, index: LinearGradientArgumentIndex.pointUV0)
                encoder.setBytes(&axisUV, length: MemoryLayout<SIMD2<Float>>.stride, index: LinearGradientArgumentIndex.axisUV)
                if yWidth > 0 && yHeight > 0 {
                    encoder.setComputePipelineState(linearGradientLumaPipeline)
                    encoder.setBytes(&offsetXY, length: MemoryLayout<SIMD2<UInt32>>.stride, index: LinearGradientArgumentIndex.offsetXY)
                    encoder.setBytes(&luma0, length: MemoryLayout<Float16>.stride, index: LinearGradientArgumentIndex.luma0)
                    encoder.setBytes(&alpha0, length: MemoryLayout<Float16>.stride, index: LinearGradientArgumentIndex.alpha0)
                    encoder.setBytes(&luma1, length: MemoryLayout<Float16>.stride, index: LinearGradientArgumentIndex.luma1)
                    encoder.setBytes(&alpha1, length: MemoryLayout<Float16>.stride, index: LinearGradientArgumentIndex.alpha1)
                    dispatch(encoder: encoder, pipeline: linearGradientLumaPipeline, width: yWidth, height: yHeight)
                }
                if chromaWidth > 0 && chromaHeight > 0 {
                    encoder.setComputePipelineState(linearGradientChromaPipeline)
                    encoder.setBytes(&chromaOffsetXY, length: MemoryLayout<SIMD2<UInt32>>.stride, index: LinearGradientArgumentIndex.offsetXY)
                    encoder.setBytes(&chroma0, length: MemoryLayout<SIMD2<Float16>>.stride, index: LinearGradientArgumentIndex.chroma0)
                    encoder.setBytes(&alpha0, length: MemoryLayout<Float16>.stride, index: LinearGradientArgumentIndex.alpha0)
                    encoder.setBytes(&chroma1, length: MemoryLayout<SIMD2<Float16>>.stride, index: LinearGradientArgumentIndex.chroma1)
                    encoder.setBytes(&alpha1, length: MemoryLayout<Float16>.stride, index: LinearGradientArgumentIndex.alpha1)
                    dispatch(encoder: encoder, pipeline: linearGradientChromaPipeline, width: chromaWidth, height: chromaHeight)
                }
                case let .radialGradient(component):
                let innerYUVColor = Self.fullRangeYUVColor(from: component.innerColor)
                let outerYUVColor = Self.fullRangeYUVColor(from: component.outerColor)
                let bounds = component.destinationRect
                var offsetXY = SIMD2<UInt32>(bounds.x, bounds.y)
                let yWidth = Int(bounds.z - bounds.x)
                let yHeight = Int(bounds.w - bounds.y)
                let chromaX0 = (bounds.x + 1) / 2
                let chromaY0 = (bounds.y + 1) / 2
                let chromaX1 = (bounds.z + 1) / 2
                let chromaY1 = (bounds.w + 1) / 2
                var chromaOffsetXY = SIMD2<UInt32>(chromaX0, chromaY0)
                let chromaWidth = Int(chromaX1 - chromaX0)
                let chromaHeight = Int(chromaY1 - chromaY0)
                var luma0 = Float16(innerYUVColor.x)
                var luma1 = Float16(outerYUVColor.x)
                var chroma0 = SIMD2<Float16>(Float16(innerYUVColor.y), Float16(innerYUVColor.z))
                var chroma1 = SIMD2<Float16>(Float16(outerYUVColor.y), Float16(outerYUVColor.z))
                var alpha0 = Float16(innerYUVColor.w * component.opacity)
                var alpha1 = Float16(outerYUVColor.w * component.opacity)
                var centerUV = component.center
                var radiusUV = SIMD2<Float>(component.innerRadius, component.outerRadius)
                bindOutput(outputY: outputLuma, outputUV: outputChroma, to: encoder)
                encoder.setBytes(&centerUV, length: MemoryLayout<SIMD2<Float>>.stride, index: RadialGradientArgumentIndex.centerUV)
                encoder.setBytes(&radiusUV, length: MemoryLayout<SIMD2<Float>>.stride, index: RadialGradientArgumentIndex.radiusUV)
                if yWidth > 0 && yHeight > 0 {
                    encoder.setComputePipelineState(radialGradientLumaPipeline)
                    encoder.setBytes(&offsetXY, length: MemoryLayout<SIMD2<UInt32>>.stride, index: RadialGradientArgumentIndex.offsetXY)
                    encoder.setBytes(&luma0, length: MemoryLayout<Float16>.stride, index: RadialGradientArgumentIndex.luma0)
                    encoder.setBytes(&alpha0, length: MemoryLayout<Float16>.stride, index: RadialGradientArgumentIndex.alpha0)
                    encoder.setBytes(&luma1, length: MemoryLayout<Float16>.stride, index: RadialGradientArgumentIndex.luma1)
                    encoder.setBytes(&alpha1, length: MemoryLayout<Float16>.stride, index: RadialGradientArgumentIndex.alpha1)
                    dispatch(encoder: encoder, pipeline: radialGradientLumaPipeline, width: yWidth, height: yHeight)
                }
                if chromaWidth > 0 && chromaHeight > 0 {
                    encoder.setComputePipelineState(radialGradientChromaPipeline)
                    encoder.setBytes(&chromaOffsetXY, length: MemoryLayout<SIMD2<UInt32>>.stride, index: RadialGradientArgumentIndex.offsetXY)
                    encoder.setBytes(&chroma0, length: MemoryLayout<SIMD2<Float16>>.stride, index: RadialGradientArgumentIndex.chroma0)
                    encoder.setBytes(&alpha0, length: MemoryLayout<Float16>.stride, index: RadialGradientArgumentIndex.alpha0)
                    encoder.setBytes(&chroma1, length: MemoryLayout<SIMD2<Float16>>.stride, index: RadialGradientArgumentIndex.chroma1)
                    encoder.setBytes(&alpha1, length: MemoryLayout<Float16>.stride, index: RadialGradientArgumentIndex.alpha1)
                    dispatch(encoder: encoder, pipeline: radialGradientChromaPipeline, width: chromaWidth, height: chromaHeight)
                }
                case let .conicGradient(component):
                let startYUVColor = Self.fullRangeYUVColor(from: component.startColor)
                let endYUVColor = Self.fullRangeYUVColor(from: component.endColor)
                let bounds = component.destinationRect
                var offsetXY = SIMD2<UInt32>(bounds.x, bounds.y)
                let yWidth = Int(bounds.z - bounds.x)
                let yHeight = Int(bounds.w - bounds.y)
                let chromaX0 = (bounds.x + 1) / 2
                let chromaY0 = (bounds.y + 1) / 2
                let chromaX1 = (bounds.z + 1) / 2
                let chromaY1 = (bounds.w + 1) / 2
                var chromaOffsetXY = SIMD2<UInt32>(chromaX0, chromaY0)
                let chromaWidth = Int(chromaX1 - chromaX0)
                let chromaHeight = Int(chromaY1 - chromaY0)
                var luma0 = Float16(startYUVColor.x)
                var luma1 = Float16(endYUVColor.x)
                var chroma0 = SIMD2<Float16>(Float16(startYUVColor.y), Float16(startYUVColor.z))
                var chroma1 = SIMD2<Float16>(Float16(endYUVColor.y), Float16(endYUVColor.z))
                var alpha0 = Float16(startYUVColor.w * component.opacity)
                var alpha1 = Float16(endYUVColor.w * component.opacity)
                var centerUV = component.center
                var startAngleRadians = component.startAngleRadians
                bindOutput(outputY: outputLuma, outputUV: outputChroma, to: encoder)
                encoder.setBytes(&centerUV, length: MemoryLayout<SIMD2<Float>>.stride, index: ConicGradientArgumentIndex.centerUV)
                encoder.setBytes(&startAngleRadians, length: MemoryLayout<Float>.stride, index: ConicGradientArgumentIndex.startAngleRadians)
                if yWidth > 0 && yHeight > 0 {
                    encoder.setComputePipelineState(conicGradientLumaPipeline)
                    encoder.setBytes(&offsetXY, length: MemoryLayout<SIMD2<UInt32>>.stride, index: ConicGradientArgumentIndex.offsetXY)
                    encoder.setBytes(&luma0, length: MemoryLayout<Float16>.stride, index: ConicGradientArgumentIndex.luma0)
                    encoder.setBytes(&alpha0, length: MemoryLayout<Float16>.stride, index: ConicGradientArgumentIndex.alpha0)
                    encoder.setBytes(&luma1, length: MemoryLayout<Float16>.stride, index: ConicGradientArgumentIndex.luma1)
                    encoder.setBytes(&alpha1, length: MemoryLayout<Float16>.stride, index: ConicGradientArgumentIndex.alpha1)
                    dispatch(encoder: encoder, pipeline: conicGradientLumaPipeline, width: yWidth, height: yHeight)
                }
                if chromaWidth > 0 && chromaHeight > 0 {
                    encoder.setComputePipelineState(conicGradientChromaPipeline)
                    encoder.setBytes(&chromaOffsetXY, length: MemoryLayout<SIMD2<UInt32>>.stride, index: ConicGradientArgumentIndex.offsetXY)
                    encoder.setBytes(&chroma0, length: MemoryLayout<SIMD2<Float16>>.stride, index: ConicGradientArgumentIndex.chroma0)
                    encoder.setBytes(&alpha0, length: MemoryLayout<Float16>.stride, index: ConicGradientArgumentIndex.alpha0)
                    encoder.setBytes(&chroma1, length: MemoryLayout<SIMD2<Float16>>.stride, index: ConicGradientArgumentIndex.chroma1)
                    encoder.setBytes(&alpha1, length: MemoryLayout<Float16>.stride, index: ConicGradientArgumentIndex.alpha1)
                    dispatch(encoder: encoder, pipeline: conicGradientChromaPipeline, width: chromaWidth, height: chromaHeight)
                }
            case let .cameraInput(component):
                let source = try makeBoundSource(component.source)
                let inputNv12DeviceVariant = CompositorShaderRegistry.InputNv12DeviceKernelVariant.r0
                let sourceRange = resolvedInputNv12DeviceSourceRange(
                    component.colorRangeOverride,
                    detectedRange: source.range
                )
                let bounds = component.destinationRect
                var offsetXY = SIMD2<UInt32>(bounds.x, bounds.y)
                let yWidth = Int(bounds.z - bounds.x)
                let yHeight = Int(bounds.w - bounds.y)
                let chromaX0 = (bounds.x + 1) / 2
                let chromaY0 = (bounds.y + 1) / 2
                let chromaX1 = (bounds.z + 1) / 2
                let chromaY1 = (bounds.w + 1) / 2
                var chromaOffsetXY = SIMD2<UInt32>(chromaX0, chromaY0)
                let chromaWidth = Int(chromaX1 - chromaX0)
                let chromaHeight = Int(chromaY1 - chromaY0)
                let sourceUV0 = SIMD2<Float>(component.sourceRect.x, component.sourceRect.y)
                let sourceUVScale0 = SIMD2<Float>(component.sourceRect.z, component.sourceRect.w)
                bindOutput(outputY: outputLuma, outputUV: outputChroma, to: encoder)
                bind(source, textureOffset: 2, to: encoder)
                // sourceUV* is Crop and belongs to the input pipeline. The
                // destination offsets below are dynamic command arguments.
                let inputNv12DevicePipelines = try shaderRegistry.inputNv12DevicePipelines(
                    variant: inputNv12DeviceVariant,
                    alphaMaskKind: source.alphaMaskKind,
                    sourceUV0: sourceUV0,
                    sourceUVScale0: sourceUVScale0,
                    sourceRange: sourceRange
                )
                if yWidth > 0 && yHeight > 0 {
                    encoder.setComputePipelineState(inputNv12DevicePipelines.luma)
                    encoder.setBytes(&offsetXY, length: MemoryLayout<SIMD2<UInt32>>.stride, index: InputNv12DeviceArgumentIndex.offsetXY)
                    dispatch(encoder: encoder, pipeline: inputNv12DevicePipelines.luma, width: yWidth, height: yHeight)
                }
                if chromaWidth > 0 && chromaHeight > 0 {
                    encoder.setComputePipelineState(inputNv12DevicePipelines.chroma)
                    encoder.setBytes(&chromaOffsetXY, length: MemoryLayout<SIMD2<UInt32>>.stride, index: InputNv12DeviceArgumentIndex.offsetXY)
                    dispatch(encoder: encoder, pipeline: inputNv12DevicePipelines.chroma, width: chromaWidth, height: chromaHeight)
                }
                case let .testPattern(component):
                let bounds = component.destinationRect
                var offsetXY = SIMD2<UInt32>(bounds.x, bounds.y)
                let yWidth = Int(bounds.z - bounds.x)
                let yHeight = Int(bounds.w - bounds.y)
                let chromaX0 = (bounds.x + 1) / 2
                let chromaY0 = (bounds.y + 1) / 2
                let chromaX1 = (bounds.z + 1) / 2
                let chromaY1 = (bounds.w + 1) / 2
                var chromaOffsetXY = SIMD2<UInt32>(chromaX0, chromaY0)
                let chromaWidth = Int(chromaX1 - chromaX0)
                let chromaHeight = Int(chromaY1 - chromaY0)
                var timeSeconds = component.timeSeconds
                bindOutput(outputY: outputLuma, outputUV: outputChroma, to: encoder)
                if yWidth > 0 && yHeight > 0 {
                    encoder.setComputePipelineState(testPatternLumaPipeline)
                    encoder.setBytes(&offsetXY, length: MemoryLayout<SIMD2<UInt32>>.stride, index: TestPatternArgumentIndex.offsetXY)
                    encoder.setBytes(&timeSeconds, length: MemoryLayout<Float>.stride, index: TestPatternArgumentIndex.timeSeconds)
                    dispatch(encoder: encoder, pipeline: testPatternLumaPipeline, width: yWidth, height: yHeight)
                }
                if chromaWidth > 0 && chromaHeight > 0 {
                    encoder.setComputePipelineState(testPatternChromaPipeline)
                    encoder.setBytes(&chromaOffsetXY, length: MemoryLayout<SIMD2<UInt32>>.stride, index: TestPatternArgumentIndex.offsetXY)
                    encoder.setBytes(&timeSeconds, length: MemoryLayout<Float>.stride, index: TestPatternArgumentIndex.timeSeconds)
                    dispatch(encoder: encoder, pipeline: testPatternChromaPipeline, width: chromaWidth, height: chromaHeight)
                }
                }
                encoder.endEncoding()
            } catch {
                encoder.endEncoding()
                throw error
            }
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if commandBuffer.status == .error {
            let nsError = commandBuffer.error as NSError?
            Self.logger.error(
                "Command buffer failed status=\(commandBuffer.status.rawValue, privacy: .public) errorDomain=\(nsError?.domain ?? "nil", privacy: .public) errorCode=\(nsError?.code ?? 0, privacy: .public)"
            )
            throw VideoCompositorError.renderFailed
        }
    }

    private struct BoundSource {
        var range: SourceRange
        var texture0: MTLTexture
        var texture1: MTLTexture
        var alphaTexture: MTLTexture?
        var alphaMaskKind: MetalVideoAlphaMaskKind?
    }

    private struct OutputTexturePair {
        var lumaMetalTexture: CVMetalTexture
        var chromaMetalTexture: CVMetalTexture
    }

    private struct OutputTextures {
        var luma: MTLTexture
        var chroma: MTLTexture
    }

    private func makeBoundSource(_ source: MetalVideoSource) throws -> BoundSource {
        switch source {
        case let .nv12Textures(
            pixelBuffer,
            lumaMetalTexture,
            chromaMetalTexture,
            alphaTexture,
            alphaMaskKind,
            _
        ):
            return try makeBoundSource(
                pixelBuffer: pixelBuffer,
                lumaMetalTexture: lumaMetalTexture,
                chromaMetalTexture: chromaMetalTexture,
                alphaTexture: alphaTexture,
                alphaMaskKind: alphaMaskKind
            )
        }
    }

    private func makeBoundSource(
        pixelBuffer: CVPixelBuffer,
        lumaMetalTexture: CVMetalTexture,
        chromaMetalTexture: CVMetalTexture,
        alphaTexture: MTLTexture?,
        alphaMaskKind: MetalVideoAlphaMaskKind?
    ) throws -> BoundSource {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let sourceRange: SourceRange
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            sourceRange = .video
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            sourceRange = .full
        default:
            throw VideoCompositorError.unsupportedPixelBufferFormat(pixelFormat)
        }

        guard let lumaTexture = CVMetalTextureGetTexture(lumaMetalTexture),
              let chromaTexture = CVMetalTextureGetTexture(chromaMetalTexture) else {
            throw VideoCompositorError.textureCreationFailed(kCVReturnInvalidArgument)
        }

        return BoundSource(
            range: sourceRange,
            texture0: lumaTexture,
            texture1: chromaTexture,
            alphaTexture: alphaTexture,
            alphaMaskKind: alphaMaskKind
        )
    }

    private func makeOutputPixelBuffer() throws -> CVPixelBuffer {
        try outputCanvasResourceManager.pixelBuffer(for: outputPixelBufferRequest)
    }

    private func outputTextures(
        for pixelBuffer: CVPixelBuffer,
        reusingOutputTextures: Bool
    ) throws -> OutputTextures {
        guard reusingOutputTextures else {
            let outputTextures = try makeOutputTextures(for: pixelBuffer)
            return OutputTextures(luma: outputTextures.luma, chroma: outputTextures.chroma)
        }

        let identity = Self.pixelBufferIdentity(pixelBuffer)
        if let cached = outputTextureCache[identity],
           let luma = CVMetalTextureGetTexture(cached.lumaMetalTexture),
           let chroma = CVMetalTextureGetTexture(cached.chromaMetalTexture) {
            return OutputTextures(luma: luma, chroma: chroma)
        }

        let outputTextures = try makeOutputTextures(for: pixelBuffer)
        outputTextureCache[identity] = OutputTexturePair(
            lumaMetalTexture: outputTextures.lumaMetalTexture,
            chromaMetalTexture: outputTextures.chromaMetalTexture
        )
        outputTextureCacheOrder.removeAll { $0 == identity }
        outputTextureCacheOrder.append(identity)
        trimOutputTextureCache()
        return OutputTextures(luma: outputTextures.luma, chroma: outputTextures.chroma)
    }

    private struct MadeOutputTextures {
        var luma: MTLTexture
        var chroma: MTLTexture
        var lumaMetalTexture: CVMetalTexture
        var chromaMetalTexture: CVMetalTexture
    }

    private func makeOutputTextures(for pixelBuffer: CVPixelBuffer) throws -> MadeOutputTextures {
        let lumaMetalTexture = try metalTexture(
            from: pixelBuffer,
            pixelFormat: .r8Uint,
            width: configuration.width,
            height: configuration.height,
            planeIndex: 0
        )
        let chromaMetalTexture = try metalTexture(
            from: pixelBuffer,
            pixelFormat: .rg8Uint,
            width: configuration.width / 2,
            height: configuration.height / 2,
            planeIndex: 1
        )

        guard let luma = CVMetalTextureGetTexture(lumaMetalTexture),
              let chroma = CVMetalTextureGetTexture(chromaMetalTexture) else {
            throw VideoCompositorError.textureCreationFailed(kCVReturnInvalidArgument)
        }
        return MadeOutputTextures(
            luma: luma,
            chroma: chroma,
            lumaMetalTexture: lumaMetalTexture,
            chromaMetalTexture: chromaMetalTexture
        )
    }

    private func trimOutputTextureCache() {
        let limit = max(configuration.pixelBufferPoolMinimumBufferCount * 2, 8)
        while outputTextureCacheOrder.count > limit {
            let removedIdentity = outputTextureCacheOrder.removeFirst()
            outputTextureCache[removedIdentity] = nil
        }
    }

    private func resolvedInputNv12DeviceSourceRange(
        _ colorRangeOverride: CameraInputColorRangeOverride,
        detectedRange: SourceRange
    ) -> CompositorShaderRegistry.InputNv12DeviceSourceRange {
        switch colorRangeOverride {
        case .unspecified:
            detectedRange == .video ? .video : .full
        case .videoRange:
            .video
        case .fullRange:
            .full
        }
    }

    private func metalTexture(
        from pixelBuffer: CVPixelBuffer,
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
        guard status == kCVReturnSuccess,
              let metalTexture else {
            Self.logger.error(
                "CVMetalTextureCacheCreateTextureFromImage failed status=\(status, privacy: .public) requestedPixelFormat=\(pixelFormat.rawValue, privacy: .public) planeIndex=\(planeIndex, privacy: .public) width=\(width, privacy: .public) height=\(height, privacy: .public) pixelBufferFormat=\(CVPixelBufferGetPixelFormatType(pixelBuffer), privacy: .public) pixelBufferWidth=\(CVPixelBufferGetWidth(pixelBuffer), privacy: .public) pixelBufferHeight=\(CVPixelBufferGetHeight(pixelBuffer), privacy: .public) planeCount=\(CVPixelBufferGetPlaneCount(pixelBuffer), privacy: .public)"
            )
            throw VideoCompositorError.textureCreationFailed(status)
        }
        return metalTexture
    }

    private func bindOutput(outputY: MTLTexture, outputUV: MTLTexture, to encoder: MTLComputeCommandEncoder) {
        encoder.setTexture(outputY, index: 0)
        encoder.setTexture(outputUV, index: 1)
    }

    private func bind(_ source: BoundSource, textureOffset: Int, to encoder: MTLComputeCommandEncoder) {
        encoder.setTexture(source.texture0, index: textureOffset)
        encoder.setTexture(source.texture1, index: textureOffset + 1)
        if let alphaTexture = source.alphaTexture {
            encoder.setTexture(alphaTexture, index: textureOffset + 2)
        }
    }

    private func dispatch(encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState) {
        dispatch(encoder: encoder, pipeline: pipeline, width: configuration.width, height: configuration.height)
    }

    private func dispatch(encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let threadgroupWidth = pipeline.threadExecutionWidth
        let threadgroupHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadgroupWidth)
        let threadsPerThreadgroup = MTLSize(width: threadgroupWidth, height: threadgroupHeight, depth: 1)
        let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
    }

    private static func fullRangeYUVColor(from rgba: SIMD4<Float>) -> SIMD4<Float> {
        let rgb = SIMD3<Float>(
            clamp(rgba.x, min: 0, max: 1),
            clamp(rgba.y, min: 0, max: 1),
            clamp(rgba.z, min: 0, max: 1)
        )
        let yFull = rgb.x * 0.2126 + rgb.y * 0.7152 + rgb.z * 0.0722
        let cb = (rgb.z - yFull) / 1.8556
        let cr = (rgb.x - yFull) / 1.5748
        let u = 0.5 + cb
        let v = 0.5 + cr
        return SIMD4<Float>(
            clamp(yFull, min: 0, max: 1),
            clamp(u, min: 0, max: 1),
            clamp(v, min: 0, max: 1),
            rgba.w
        )
    }

    private static func uint8StorageValue(fromUnit value: Float) -> UInt32 {
        UInt32(clamp(value, min: 0, max: 1) * 255 + 0.5)
    }

    private static func clamp(_ value: Float, min: Float, max: Float) -> Float {
        Swift.max(min, Swift.min(max, value))
    }

    private static func componentName(_ component: MetalVideoComponentCommand) -> String {
        switch component {
        case .solidColor:
            "solidColor"
        case .linearGradient:
            "linearGradient"
        case .radialGradient:
            "radialGradient"
        case .conicGradient:
            "conicGradient"
        case .cameraInput:
            "cameraInput"
        case .testPattern:
            "testPattern"
        }
    }

    private static func componentKindCode(_ component: MetalVideoComponentCommand) -> Int {
        switch component {
        case .solidColor:
            0
        case .linearGradient:
            1
        case .radialGradient:
            2
        case .conicGradient:
            3
        case .cameraInput:
            4
        case .testPattern:
            5
        }
    }

    private static func pixelBufferIdentity(_ pixelBuffer: CVPixelBuffer) -> UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(pixelBuffer).toOpaque())
    }

    private static let logger = Logger(
        subsystem: "tokyo.kaito.ldtx",
        category: "VideoCompositor"
    )

    private static func diagnosticFourCC(_ value: OSType) -> String {
        let scalars = [
            UnicodeScalar((value >> 24) & 0xff),
            UnicodeScalar((value >> 16) & 0xff),
            UnicodeScalar((value >> 8) & 0xff),
            UnicodeScalar(value & 0xff)
        ]
        let string = scalars.compactMap { $0 }.map(String.init).joined()
        return string.isEmpty ? "\(value)" : "\(string)(\(value))"
    }

    public static func makePreviewNV12ToBGRAPipeline(device: MTLDevice) throws -> MTLComputePipelineState {
        let library = try makeShaderLibrary(device: device)
        guard let function = library.makeFunction(name: "previewNV12ToBGRAKernel") else {
            throw VideoCompositorError.shaderCompilationFailed("previewNV12ToBGRAKernel was not found.")
        }
        return try device.makeComputePipelineState(function: function)
    }

    public static func makePreviewLumaToGrayscaleBGRAPipeline(device: MTLDevice) throws -> MTLComputePipelineState {
        let library = try makeShaderLibrary(device: device)
        guard let function = library.makeFunction(name: "previewLumaToGrayscaleBGRAKernel") else {
            throw VideoCompositorError.shaderCompilationFailed("previewLumaToGrayscaleBGRAKernel was not found.")
        }
        return try device.makeComputePipelineState(function: function)
    }

    private static func makeShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
        try MetalShaderLibraryLoader.makeLibrary(
            device: device,
            bundleToken: VideoCompositorBundleToken.self
        )
    }
}

private final class VideoCompositorBundleToken: NSObject {}
