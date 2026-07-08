// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreML
import CoreVideo
import Darwin
import Foundation
#if canImport(Metal)
import Metal
#endif

public enum MediaPipeSelfieSegmentationModelError: Error, LocalizedError {
    case allocationFailed
    case shaderFunctionMissing(String)

    public var errorDescription: String? {
        switch self {
        case .allocationFailed:
            "MediaPipe Selfie Segmentation buffer allocation failed."
        case let .shaderFunctionMissing(name):
            "MediaPipe Selfie Segmentation shader function was not found: \(name)."
        }
    }
}

public final class MediaPipeSelfieSegmentationModel {
    fileprivate static let inputWidth = 256
    fileprivate static let inputHeight = 144
    fileprivate static let outputElementCount = inputWidth * inputHeight
    public static let rawMaskWidth = inputWidth
    public static let rawMaskHeight = inputHeight
    private static let modelLoadingLock = NSLock()

    private let model: MLModel
    private let inputArray: MLMultiArray
    private let rawMaskBacking: MLMultiArray
    private let predictionOptions: MLPredictionOptions
    #if canImport(Metal)
    private let inputBuffer: MTLBuffer?
    private let inputPreprocessor: MediaPipeSelfieSegmentationInputPreprocessor?
    #endif

    #if canImport(Metal)
    public init(
        modelURL: URL,
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil,
        metalDevice: MTLDevice? = nil
    ) throws {
        model = try Self.modelLoadingLock.withLock {
            try Self.makeModel(at: modelURL, configuration: Self.makeModelConfiguration())
        }
        if let metalDevice {
            let inputStorage = try Self.makeMetalBackedInputArray(device: metalDevice)
            inputArray = inputStorage.array
            inputBuffer = inputStorage.buffer
            inputPreprocessor = try MediaPipeSelfieSegmentationInputPreprocessor(
                device: metalDevice,
                inputBuffer: inputStorage.buffer,
                inputWidth: Self.inputWidth,
                inputHeight: Self.inputHeight
            )
        } else {
            inputArray = try Self.makeInputArray()
            inputBuffer = nil
            inputPreprocessor = nil
        }
        rawMaskBacking = try Self.makeRawMaskBacking()
        let predictionOptions = MLPredictionOptions()
        predictionOptions.outputBackings = [
            "alphas": rawMaskBacking
        ]
        self.predictionOptions = predictionOptions
    }
    #else
    public init(modelURL: URL, sourceWidth: Int? = nil, sourceHeight: Int? = nil) throws {
        model = try Self.modelLoadingLock.withLock {
            try Self.makeModel(at: modelURL, configuration: Self.makeModelConfiguration())
        }
        inputArray = try Self.makeInputArray()
        rawMaskBacking = try Self.makeRawMaskBacking()
        let predictionOptions = MLPredictionOptions()
        predictionOptions.outputBackings = [
            "alphas": rawMaskBacking
        ]
        self.predictionOptions = predictionOptions
    }
    #endif

    public func renderAlphaMaskPixelBuffer(
        _ source: CVPixelBuffer,
        to alphaMask: CVPixelBuffer
    ) -> Bool {
        guard CVPixelBufferGetPlaneCount(source) == 2,
              CVPixelBufferGetPixelFormatType(alphaMask) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferGetWidth(source) == CVPixelBufferGetWidth(alphaMask),
              CVPixelBufferGetHeight(source) == CVPixelBufferGetHeight(alphaMask) else {
            return false
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        let inputArraysFilled = fillInputArrays(from: source)
        CVPixelBufferUnlockBaseAddress(source, .readOnly)

        guard inputArraysFilled,
              let prediction = predictSegmentation(),
              let rawMask = prediction.rawMask else {
            return false
        }

        CVPixelBufferLockBaseAddress(alphaMask, [])
        defer {
            CVPixelBufferUnlockBaseAddress(alphaMask, [])
        }
        return applyRawMask(rawMask, to: alphaMask)
    }

    #if canImport(Metal)
    public func renderRawMaskTexture(
        _ source: CVPixelBuffer,
        to rawMaskTexture: MTLTexture
    ) -> Bool {
        guard CVPixelBufferGetPlaneCount(source) == 2,
              rawMaskTexture.pixelFormat == .r16Float,
              rawMaskTexture.width == Self.rawMaskWidth,
              rawMaskTexture.height == Self.rawMaskHeight else {
            return false
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        let inputArraysFilled = fillInputArrays(from: source)
        CVPixelBufferUnlockBaseAddress(source, .readOnly)

        return inputArraysFilled && renderPrediction(to: rawMaskTexture)
    }

    public func renderRawMaskTexture(
        _ source: CVPixelBuffer,
        lumaTexture: MTLTexture,
        chromaTexture: MTLTexture,
        to rawMaskTexture: MTLTexture
    ) -> Bool {
        guard CVPixelBufferGetPlaneCount(source) == 2,
              rawMaskTexture.pixelFormat == .r16Float,
              rawMaskTexture.width == Self.rawMaskWidth,
              rawMaskTexture.height == Self.rawMaskHeight,
              let inputPreprocessor else {
            return false
        }

        guard inputPreprocessor.fillInputArray(
            lumaTexture: lumaTexture,
            chromaTexture: chromaTexture,
            sourcePixelFormat: CVPixelBufferGetPixelFormatType(source)
        ) else {
            return false
        }

        return renderPrediction(to: rawMaskTexture)
    }
    #endif

    #if canImport(Metal)
    private func renderPrediction(to rawMaskTexture: MTLTexture) -> Bool {
        guard let prediction = predictSegmentation(),
              let rawMask = prediction.rawMask,
              rawMask.count >= Self.outputElementCount else {
            return false
        }

        rawMaskTexture.replace(
            region: MTLRegionMake2D(0, 0, Self.rawMaskWidth, Self.rawMaskHeight),
            mipmapLevel: 0,
            withBytes: rawMask.dataPointer,
            bytesPerRow: Int(truncating: rawMask.strides[2]) * MemoryLayout<Float16>.stride
        )
        return true
    }
    #endif

    private func fillInputArrays(from pixelBuffer: CVPixelBuffer) -> Bool {
        guard let lumaBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chromaBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            return false
        }

        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let lumaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let luma = lumaBaseAddress.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBaseAddress.assumingMemoryBound(to: UInt8.self)
        let input = inputArray.dataPointer.assumingMemoryBound(to: Float16.self)
        let plane = Self.inputWidth * Self.inputHeight
        let isVideoRange = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        for y in 0..<Self.inputHeight {
            let sourceY = min(y * sourceHeight / Self.inputHeight, sourceHeight - 1)
            let chromaY = min(sourceY / 2, chromaHeight - 1)
            for x in 0..<Self.inputWidth {
                let sourceX = min(x * sourceWidth / Self.inputWidth, sourceWidth - 1)
                let chromaX = min(sourceX / 2, chromaWidth - 1)
                let lumaValue = luma[sourceY * lumaBytesPerRow + sourceX]
                let chromaOffset = chromaY * chromaBytesPerRow + chromaX * 2
                let chromaU = chroma[chromaOffset]
                let chromaV = chroma[chromaOffset + 1]
                let rgb = Self.rgbFromYUV(
                    y: lumaValue,
                    u: chromaU,
                    v: chromaV,
                    isVideoRange: isVideoRange
                )
                let inputIndex = y * Self.inputWidth + x
                input[inputIndex] = Float16(rgb.r)
                input[plane + inputIndex] = Float16(rgb.g)
                input[plane * 2 + inputIndex] = Float16(rgb.b)
            }
        }
        return true
    }

    private func predictSegmentation() -> SegmentationPrediction? {
        do {
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "pixel_values": MLFeatureValue(multiArray: inputArray)
            ])
            let output = try model.prediction(from: input, options: predictionOptions)
            return SegmentationPrediction(
                rawMask: output.featureValue(for: "alphas")?.multiArrayValue
            )
        } catch {
            return nil
        }
    }

    private static func makeModel(at modelURL: URL, configuration: MLModelConfiguration) throws -> MLModel {
        if modelURL.pathExtension == "mlmodelc" {
            return try MLModel(contentsOf: modelURL, configuration: configuration)
        }
        let compiledURL = try MLModel.compileModel(at: modelURL)
        return try MLModel(contentsOf: compiledURL, configuration: configuration)
    }

    private static func makeModelConfiguration() -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        return configuration
    }

    private static func makeInputArray() throws -> MLMultiArray {
        try MLMultiArray(
            shape: [1, 3, NSNumber(value: inputHeight), NSNumber(value: inputWidth)],
            dataType: .float16
        )
    }

    #if canImport(Metal)
    private static func makeMetalBackedInputArray(
        device: MTLDevice
    ) throws -> (array: MLMultiArray, buffer: MTLBuffer) {
        let shape = [1, 3, inputHeight, inputWidth].map(NSNumber.init(value:))
        let strides = [3 * inputHeight * inputWidth, inputHeight * inputWidth, inputWidth, 1].map(
            NSNumber.init(value:)
        )
        let byteCount = 3 * inputHeight * inputWidth * MemoryLayout<Float16>.stride
        guard let buffer = device.makeBuffer(length: byteCount, options: [.storageModeShared]) else {
            throw MediaPipeSelfieSegmentationModelError.allocationFailed
        }
        let array = try MLMultiArray(
            dataPointer: buffer.contents(),
            shape: shape,
            dataType: .float16,
            strides: strides,
            deallocator: { _ in }
        )
        return (array, buffer)
    }
    #endif

    private static func makeRawMaskBacking() throws -> MLMultiArray {
        let shape = [1, 1, inputHeight, inputWidth].map(NSNumber.init(value:))
        let strides = [inputHeight * inputWidth, inputHeight * inputWidth, inputWidth, 1].map(NSNumber.init(value:))
        let byteCount = outputElementCount * MemoryLayout<Float16>.stride
        let alignment = max(MemoryLayout<Float16>.alignment, Int(getpagesize()))
        var pointer: UnsafeMutableRawPointer?
        guard posix_memalign(&pointer, alignment, byteCount) == 0,
              let pointer else {
            throw MediaPipeSelfieSegmentationModelError.allocationFailed
        }

        do {
            return try MLMultiArray(
                dataPointer: pointer,
                shape: shape,
                dataType: .float16,
                strides: strides,
                deallocator: { pointer in
                    free(pointer)
                }
            )
        } catch {
            free(pointer)
            throw error
        }
    }

    private func applyRawMask(_ mask: MLMultiArray, to alphaMask: CVPixelBuffer) -> Bool {
        guard mask.count >= Self.outputElementCount,
              let alphaMaskBaseAddress = CVPixelBufferGetBaseAddress(alphaMask) else {
            return false
        }

        let width = CVPixelBufferGetWidth(alphaMask)
        let height = CVPixelBufferGetHeight(alphaMask)
        let alphaMaskBytesPerRow = CVPixelBufferGetBytesPerRow(alphaMask)
        let alphaMaskValues = alphaMaskBaseAddress.assumingMemoryBound(to: UInt8.self)
        let maskValues = mask.dataPointer.assumingMemoryBound(to: Float16.self)
        let maskIndex = SingleChannelMaskIndex(mask: mask)

        for y in 0..<height {
            let maskY = Self.nearestInputCoordinate(
                outputCoordinate: y,
                outputLength: height,
                inputLength: Self.inputHeight
            )
            for x in 0..<width {
                let maskX = Self.nearestInputCoordinate(
                    outputCoordinate: x,
                    outputLength: width,
                    inputLength: Self.inputWidth
                )
                let alpha = Self.clamp01(Float(maskValues[maskIndex.offset(y: maskY, x: maskX)]))
                alphaMaskValues[y * alphaMaskBytesPerRow + x] = UInt8(
                    min(max(Int((alpha * 255).rounded()), 0), 255)
                )
            }
        }
        return true
    }

    private static func rgbFromYUV(
        y: UInt8,
        u: UInt8,
        v: UInt8,
        isVideoRange: Bool
    ) -> (r: Float, g: Float, b: Float) {
        let chromaScale: Float
        let luma = lumaUnit(y: y, isVideoRange: isVideoRange)
        if isVideoRange {
            chromaScale = 224
        } else {
            chromaScale = 255
        }
        let cb = (Float(u) - 128) / chromaScale
        let cr = (Float(v) - 128) / chromaScale
        let r = luma + 1.5748 * cr
        let g = luma - 0.1873 * cb - 0.4681 * cr
        let b = luma + 1.8556 * cb
        return (clamp01(r), clamp01(g), clamp01(b))
    }

    private static func lumaUnit(y: UInt8, isVideoRange: Bool) -> Float {
        if isVideoRange {
            return clamp01((Float(y) - 16) / 219)
        }
        return Float(y) / 255
    }

    private static func clamp01(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    private static func nearestInputCoordinate(
        outputCoordinate: Int,
        outputLength: Int,
        inputLength: Int
    ) -> Int {
        let coordinate = (Float(outputCoordinate) + 0.5) * Float(inputLength) / Float(outputLength) - 0.5
        return min(max(Int(coordinate.rounded()), 0), inputLength - 1)
    }

}

private struct SegmentationPrediction {
    var rawMask: MLMultiArray?
}

#if canImport(Metal)
private final class MediaPipeSelfieSegmentationInputPreprocessor {
    private static let videoRange: UInt32 = 0
    private static let fullRange: UInt32 = 1

    private let commandQueue: MTLCommandQueue
    private let inputBuffer: MTLBuffer
    private let inputWidth: Int
    private let inputHeight: Int
    private let redPipelineState: MTLComputePipelineState
    private let greenPipelineState: MTLComputePipelineState
    private let bluePipelineState: MTLComputePipelineState

    init(
        device: MTLDevice,
        inputBuffer: MTLBuffer,
        inputWidth: Int,
        inputHeight: Int
    ) throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw MediaPipeSelfieSegmentationModelError.allocationFailed
        }
        let library = try MediaPipeSelfieSegmentationShaderLibraryLoader.makeLibrary(
            device: device,
            bundleToken: MediaPipeSelfieSegmentationModel.self
        )
        self.commandQueue = commandQueue
        self.inputBuffer = inputBuffer
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        redPipelineState = try Self.makePipelineState(
            named: "fillSelfieInputRedKernel",
            library: library,
            device: device
        )
        greenPipelineState = try Self.makePipelineState(
            named: "fillSelfieInputGreenKernel",
            library: library,
            device: device
        )
        bluePipelineState = try Self.makePipelineState(
            named: "fillSelfieInputBlueKernel",
            library: library,
            device: device
        )
    }

    func fillInputArray(
        lumaTexture: MTLTexture,
        chromaTexture: MTLTexture,
        sourcePixelFormat: OSType
    ) -> Bool {
        guard lumaTexture.pixelFormat == .r8Uint,
              chromaTexture.pixelFormat == .rg8Uint,
              let colorRange = Self.colorRange(sourcePixelFormat: sourcePixelFormat),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }

        encodeFill(
            pipelineState: redPipelineState,
            colorRange: colorRange,
            lumaTexture: lumaTexture,
            chromaTexture: chromaTexture,
            encoder: encoder
        )
        encodeFill(
            pipelineState: greenPipelineState,
            colorRange: colorRange,
            lumaTexture: lumaTexture,
            chromaTexture: chromaTexture,
            encoder: encoder
        )
        encodeFill(
            pipelineState: bluePipelineState,
            colorRange: colorRange,
            lumaTexture: lumaTexture,
            chromaTexture: chromaTexture,
            encoder: encoder
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }

    private func encodeFill(
        pipelineState: MTLComputePipelineState,
        colorRange: UInt32,
        lumaTexture: MTLTexture,
        chromaTexture: MTLTexture,
        encoder: MTLComputeCommandEncoder
    ) {
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(lumaTexture, index: 0)
        encoder.setTexture(chromaTexture, index: 1)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        var colorRange = colorRange
        encoder.setBytes(&colorRange, length: MemoryLayout<UInt32>.stride, index: 1)
        let threadsPerThreadgroup = threadsPerThreadgroup(for: pipelineState)
        encoder.dispatchThreads(
            MTLSize(width: inputWidth, height: inputHeight, depth: 1),
            threadsPerThreadgroup: threadsPerThreadgroup
        )
    }

    private func threadsPerThreadgroup(for pipelineState: MTLComputePipelineState) -> MTLSize {
        let width = pipelineState.threadExecutionWidth
        let height = max(1, pipelineState.maxTotalThreadsPerThreadgroup / width)
        return MTLSize(width: width, height: height, depth: 1)
    }

    private static func makePipelineState(
        named name: String,
        library: MTLLibrary,
        device: MTLDevice
    ) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw MediaPipeSelfieSegmentationModelError.shaderFunctionMissing(name)
        }
        return try device.makeComputePipelineState(function: function)
    }

    private static func colorRange(sourcePixelFormat: OSType) -> UInt32? {
        switch sourcePixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            videoRange
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            fullRange
        default:
            nil
        }
    }
}

private enum MediaPipeSelfieSegmentationShaderLibraryLoader {
    static func makeLibrary(
        device: MTLDevice,
        bundleToken: AnyClass
    ) throws -> MTLLibrary {
        let bundle = shaderBundle(bundleToken: bundleToken)

        if let bundle,
           let library = try? device.makeDefaultLibrary(bundle: bundle) {
            return library
        }

        if let bundle,
           let library = try makeLibraryFromSource(device: device, bundle: bundle) {
            return library
        }

        if let library = device.makeDefaultLibrary() {
            return library
        }

        throw MediaPipeSelfieSegmentationModelError.shaderFunctionMissing(
            "BackgroundSegmentationShaders"
        )
    }

    private static func shaderBundle(bundleToken: AnyClass) -> Bundle? {
        #if SWIFT_PACKAGE
        .module
        #else
        Bundle(for: bundleToken)
        #endif
    }

    private static func makeLibraryFromSource(
        device: MTLDevice,
        bundle: Bundle
    ) throws -> MTLLibrary? {
        guard let sourceURL = bundle.url(
            forResource: "BackgroundSegmentationShaders",
            withExtension: "metal"
        ) else {
            return nil
        }

        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        return try device.makeLibrary(source: source, options: nil)
    }
}
#endif

private struct SingleChannelMaskIndex {
    let yStride: Int
    let xStride: Int

    init(mask: MLMultiArray) {
        yStride = Int(truncating: mask.strides[2])
        xStride = Int(truncating: mask.strides[3])
    }

    func offset(y: Int, x: Int) -> Int {
        y * yStride + x * xStride
    }
}
