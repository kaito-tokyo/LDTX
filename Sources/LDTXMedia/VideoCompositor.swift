// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
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

public enum MetalVideoComponentCommand {
    case solidColor(SolidColorComponent)
    case linearGradient(LinearGradientComponent)
    case radialGradient(RadialGradientComponent)
    case conicGradient(ConicGradientComponent)
    case cameraInput(CameraInputComponent)
    case testPattern(TestPatternComponent)
}

public enum MetalVideoSource: @unchecked Sendable {
    case pixelBuffer(CVPixelBuffer)
    case pixelBufferWithAlphaMask(CVPixelBuffer, CVPixelBuffer)
}

public protocol MetalVideoComponent: Sendable {
    func makeCommand() -> MetalVideoComponentCommand
}

public struct SolidColorComponent: MetalVideoComponent {
    public var color: SIMD4<Float>
    public var destinationRect: SIMD4<UInt32>
    public var opacity: Float

    public init(
        color: SIMD4<Float>,
        destinationRect: SIMD4<UInt32>,
        opacity: Float = 1
    ) {
        self.color = color
        self.destinationRect = destinationRect
        self.opacity = opacity
    }

    public func makeCommand() -> MetalVideoComponentCommand {
        .solidColor(self)
    }
}

public struct LinearGradientComponent: MetalVideoComponent {
    public var start: SIMD2<Float>
    public var end: SIMD2<Float>
    public var startColor: SIMD4<Float>
    public var endColor: SIMD4<Float>
    public var destinationRect: SIMD4<UInt32>

    public init(
        start: SIMD2<Float>,
        end: SIMD2<Float>,
        startColor: SIMD4<Float>,
        endColor: SIMD4<Float>,
        destinationRect: SIMD4<UInt32>
    ) {
        self.start = start
        self.end = end
        self.startColor = startColor
        self.endColor = endColor
        self.destinationRect = destinationRect
    }

    public func makeCommand() -> MetalVideoComponentCommand {
        .linearGradient(self)
    }
}

public struct RadialGradientComponent: MetalVideoComponent {
    public var center: SIMD2<Float>
    public var innerRadius: Float
    public var outerRadius: Float
    public var innerColor: SIMD4<Float>
    public var outerColor: SIMD4<Float>
    public var destinationRect: SIMD4<UInt32>
    public var destinationToSource: simd_float4x4
    public var opacity: Float

    public init(
        center: SIMD2<Float>,
        innerRadius: Float = 0,
        outerRadius: Float,
        innerColor: SIMD4<Float>,
        outerColor: SIMD4<Float>,
        destinationRect: SIMD4<UInt32>,
        destinationToSource: simd_float4x4 = matrix_identity_float4x4,
        opacity: Float = 1
    ) {
        self.center = center
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
        self.innerColor = innerColor
        self.outerColor = outerColor
        self.destinationRect = destinationRect
        self.destinationToSource = destinationToSource
        self.opacity = opacity
    }

    public func makeCommand() -> MetalVideoComponentCommand {
        .radialGradient(self)
    }
}

public struct ConicGradientComponent: MetalVideoComponent {
    public var center: SIMD2<Float>
    public var startAngleRadians: Float
    public var startColor: SIMD4<Float>
    public var endColor: SIMD4<Float>
    public var destinationRect: SIMD4<UInt32>
    public var destinationToSource: simd_float4x4
    public var opacity: Float

    public init(
        center: SIMD2<Float>,
        startAngleRadians: Float = 0,
        startColor: SIMD4<Float>,
        endColor: SIMD4<Float>,
        destinationRect: SIMD4<UInt32>,
        destinationToSource: simd_float4x4 = matrix_identity_float4x4,
        opacity: Float = 1
    ) {
        self.center = center
        self.startAngleRadians = startAngleRadians
        self.startColor = startColor
        self.endColor = endColor
        self.destinationRect = destinationRect
        self.destinationToSource = destinationToSource
        self.opacity = opacity
    }

    public func makeCommand() -> MetalVideoComponentCommand {
        .conicGradient(self)
    }
}

public struct CameraInputComponent: MetalVideoComponent {
    public var source: MetalVideoSource
    public var destinationRect: SIMD4<UInt32>
    public var sourceRect: SIMD4<Float>

    public init(
        source: MetalVideoSource,
        destinationRect: SIMD4<UInt32>,
        sourceRect: SIMD4<Float> = SIMD4<Float>(0, 0, 1, 1)
    ) {
        self.source = source
        self.destinationRect = destinationRect
        self.sourceRect = sourceRect
    }

    public func makeCommand() -> MetalVideoComponentCommand {
        .cameraInput(self)
    }
}

public struct TestPatternComponent: MetalVideoComponent {
    public var timeSeconds: Float
    public var destinationRect: SIMD4<UInt32>

    public init(
        timeSeconds: Float,
        destinationRect: SIMD4<UInt32>
    ) {
        self.timeSeconds = timeSeconds
        self.destinationRect = destinationRect
    }

    public func makeCommand() -> MetalVideoComponentCommand {
        .testPattern(self)
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
        try renderCommands(components, into: outputPixelBuffer)
        return outputPixelBuffer
    }

    public func renderCommands(_ components: [MetalVideoComponentCommand], into outputPixelBuffer: CVPixelBuffer) throws {
        guard CVPixelBufferGetWidth(outputPixelBuffer) == configuration.width,
              CVPixelBufferGetHeight(outputPixelBuffer) == configuration.height,
              CVPixelBufferGetPixelFormatType(outputPixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            Self.logger.error(
                "Invalid output pixel buffer expectedWidth=\(self.configuration.width, privacy: .public) expectedHeight=\(self.configuration.height, privacy: .public) expectedPixelFormat=\(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, privacy: .public) actualWidth=\(CVPixelBufferGetWidth(outputPixelBuffer), privacy: .public) actualHeight=\(CVPixelBufferGetHeight(outputPixelBuffer), privacy: .public) actualPixelFormat=\(CVPixelBufferGetPixelFormatType(outputPixelBuffer), privacy: .public) componentCount=\(components.count, privacy: .public)"
            )
            throw VideoCompositorError.invalidConfiguration
        }

        let outputLuma = try texture(
            from: outputPixelBuffer,
            pixelFormat: .r8Uint,
            width: configuration.width,
            height: configuration.height,
            planeIndex: 0
        )
        let outputChroma = try texture(
            from: outputPixelBuffer,
            pixelFormat: .rg8Uint,
            width: configuration.width / 2,
            height: configuration.height / 2,
            planeIndex: 1
        )

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
                let bounds = component.destinationRect
                let offsetXY = SIMD2<UInt32>(bounds.x, bounds.y)
                let yWidth = Int(bounds.z - bounds.x)
                let yHeight = Int(bounds.w - bounds.y)
                let chromaX0 = (bounds.x + 1) / 2
                let chromaY0 = (bounds.y + 1) / 2
                let chromaX1 = (bounds.z + 1) / 2
                let chromaY1 = (bounds.w + 1) / 2
                let chromaOffsetXY = SIMD2<UInt32>(chromaX0, chromaY0)
                let chromaWidth = Int(chromaX1 - chromaX0)
                let chromaHeight = Int(chromaY1 - chromaY0)
                let sourceUV0 = SIMD2<Float>(component.sourceRect.x, component.sourceRect.y)
                let sourceUVScale0 = SIMD2<Float>(component.sourceRect.z, component.sourceRect.w)
                bindOutput(outputY: outputLuma, outputUV: outputChroma, to: encoder)
                bind(source, textureOffset: 2, to: encoder)
                let inputNv12DevicePipelines = try shaderRegistry.inputNv12DevicePipelines(
                    variant: inputNv12DeviceVariant,
                    blendsWithAlpha: source.alphaTexture != nil,
                    lumaOffsetXY: offsetXY,
                    chromaOffsetXY: chromaOffsetXY,
                    sourceUV0: sourceUV0,
                    sourceUVScale0: sourceUVScale0
                )
                if yWidth > 0 && yHeight > 0 {
                    encoder.setComputePipelineState(inputNv12DevicePipelines.luma)
                    dispatch(encoder: encoder, pipeline: inputNv12DevicePipelines.luma, width: yWidth, height: yHeight)
                }
                if chromaWidth > 0 && chromaHeight > 0 {
                    encoder.setComputePipelineState(inputNv12DevicePipelines.chroma)
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
    }

    private func makeBoundSource(_ source: MetalVideoSource) throws -> BoundSource {
        switch source {
        case let .pixelBuffer(pixelBuffer):
            return try makeBoundSource(pixelBuffer: pixelBuffer, alphaMask: nil)
        case let .pixelBufferWithAlphaMask(pixelBuffer, alphaMask):
            return try makeBoundSource(pixelBuffer: pixelBuffer, alphaMask: alphaMask)
        }
    }

    private func makeBoundSource(pixelBuffer: CVPixelBuffer, alphaMask: CVPixelBuffer?) throws -> BoundSource {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            let sourceRange: SourceRange = if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
                .video
            } else {
                .full
            }
            let alphaTexture: MTLTexture?
            if let alphaMask {
                guard CVPixelBufferGetPixelFormatType(alphaMask) == kCVPixelFormatType_OneComponent8,
                      CVPixelBufferGetWidth(alphaMask) == CVPixelBufferGetWidth(pixelBuffer),
                      CVPixelBufferGetHeight(alphaMask) == CVPixelBufferGetHeight(pixelBuffer) else {
                    throw VideoCompositorError.unsupportedPixelBufferFormat(CVPixelBufferGetPixelFormatType(alphaMask))
                }
                alphaTexture = try texture(
                    from: alphaMask,
                    pixelFormat: .r8Unorm,
                    width: CVPixelBufferGetWidth(alphaMask),
                    height: CVPixelBufferGetHeight(alphaMask),
                    planeIndex: 0
                )
            } else {
                alphaTexture = nil
            }
            return BoundSource(
                range: sourceRange,
                texture0: try texture(
                    from: pixelBuffer,
                    pixelFormat: .r8Unorm,
                    width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                    height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                    planeIndex: 0
                ),
                texture1: try texture(
                    from: pixelBuffer,
                    pixelFormat: .rg8Unorm,
                    width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                    height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
                    planeIndex: 1
                ),
                alphaTexture: alphaTexture
            )
        default:
            Self.logger.error(
                "Unsupported source pixel buffer format pixelFormat=\(pixelFormat, privacy: .public) width=\(CVPixelBufferGetWidth(pixelBuffer), privacy: .public) height=\(CVPixelBufferGetHeight(pixelBuffer), privacy: .public) planeCount=\(CVPixelBufferGetPlaneCount(pixelBuffer), privacy: .public)"
            )
            throw VideoCompositorError.unsupportedPixelBufferFormat(pixelFormat)
        }
    }

    private func makeOutputPixelBuffer() throws -> CVPixelBuffer {
        try outputCanvasResourceManager.pixelBuffer(for: outputPixelBufferRequest)
    }

    private func texture(
        from pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        planeIndex: Int
    ) throws -> MTLTexture {
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
              let metalTexture,
              let texture = CVMetalTextureGetTexture(metalTexture) else {
            Self.logger.error(
                "CVMetalTextureCacheCreateTextureFromImage failed status=\(status, privacy: .public) requestedPixelFormat=\(pixelFormat.rawValue, privacy: .public) planeIndex=\(planeIndex, privacy: .public) width=\(width, privacy: .public) height=\(height, privacy: .public) pixelBufferFormat=\(CVPixelBufferGetPixelFormatType(pixelBuffer), privacy: .public) pixelBufferWidth=\(CVPixelBufferGetWidth(pixelBuffer), privacy: .public) pixelBufferHeight=\(CVPixelBufferGetHeight(pixelBuffer), privacy: .public) planeCount=\(CVPixelBufferGetPlaneCount(pixelBuffer), privacy: .public)"
            )
            throw VideoCompositorError.textureCreationFailed(status)
        }
        return texture
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

    private static func makeShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
        try MetalShaderLibraryLoader.makeLibrary(
            device: device,
            bundleToken: VideoCompositorBundleToken.self,
            sourceResourceNames: [
                "VideoCompositorShaders",
                "InputDeviceShaders"
            ]
        )
    }
}

private final class VideoCompositorBundleToken: NSObject {}
