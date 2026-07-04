// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreML
import CoreVideo
import Darwin
import Foundation

public final class MediaPipeSelfieSegmentationModel {
    fileprivate static let inputWidth = 256
    fileprivate static let inputHeight = 144
    fileprivate static let outputElementCount = inputWidth * inputHeight

    private let model: MLModel
    private let inputArray: MLMultiArray
    private let rawMaskBacking: MLMultiArray
    private let predictionOptions: MLPredictionOptions

    public init(modelURL: URL, sourceWidth: Int? = nil, sourceHeight: Int? = nil) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try Self.makeModel(at: modelURL, configuration: configuration)
        inputArray = try MLMultiArray(
            shape: [1, 3, NSNumber(value: Self.inputHeight), NSNumber(value: Self.inputWidth)],
            dataType: .float16
        )
        rawMaskBacking = try Self.makeRawMaskBacking()
        let predictionOptions = MLPredictionOptions()
        predictionOptions.outputBackings = [
            "alphas": rawMaskBacking
        ]
        self.predictionOptions = predictionOptions
    }

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

    private static func makeRawMaskBacking() throws -> MLMultiArray {
        let shape = [1, 1, inputHeight, inputWidth].map(NSNumber.init(value:))
        let strides = [inputHeight * inputWidth, inputHeight * inputWidth, inputWidth, 1].map(NSNumber.init(value:))
        let byteCount = outputElementCount * MemoryLayout<Float16>.stride
        let alignment = max(MemoryLayout<Float16>.alignment, Int(getpagesize()))
        var pointer: UnsafeMutableRawPointer?
        guard posix_memalign(&pointer, alignment, byteCount) == 0,
              let pointer else {
            throw VideoCompositorError.metalDeviceUnavailable
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
