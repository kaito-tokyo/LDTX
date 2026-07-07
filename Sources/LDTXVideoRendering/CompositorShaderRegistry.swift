// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Metal
import simd

final class CompositorShaderRegistry: @unchecked Sendable {
    enum InputNv12DeviceSourceRange: UInt32 {
        case video = 1
        case full = 2
    }

    enum InputNv12DeviceKernelVariant: CaseIterable, Hashable {
        case r0
        case r0FlipH
        case r0FlipV
        case r0FlipHV
        case r90
        case r90FlipH
        case r90FlipV
        case r90FlipHV
        case r180
        case r180FlipH
        case r180FlipV
        case r180FlipHV
        case r270
        case r270FlipH
        case r270FlipV
        case r270FlipHV

        var functionNameStem: String {
            switch self {
            case .r0:
                "inputNv12Device0"
            case .r0FlipH:
                "inputNv12Device0FlipH"
            case .r0FlipV:
                "inputNv12Device0FlipV"
            case .r0FlipHV:
                "inputNv12Device0FlipHV"
            case .r90:
                "inputNv12Device90"
            case .r90FlipH:
                "inputNv12Device90FlipH"
            case .r90FlipV:
                "inputNv12Device90FlipV"
            case .r90FlipHV:
                "inputNv12Device90FlipHV"
            case .r180:
                "inputNv12Device180"
            case .r180FlipH:
                "inputNv12Device180FlipH"
            case .r180FlipV:
                "inputNv12Device180FlipV"
            case .r180FlipHV:
                "inputNv12Device180FlipHV"
            case .r270:
                "inputNv12Device270"
            case .r270FlipH:
                "inputNv12Device270FlipH"
            case .r270FlipV:
                "inputNv12Device270FlipV"
            case .r270FlipHV:
                "inputNv12Device270FlipHV"
            }
        }

        var lumaFunctionName: String {
            "\(functionNameStem)LumaKernel"
        }

        var chromaFunctionName: String {
            "\(functionNameStem)ChromaKernel"
        }
    }

    private enum InputNv12DeviceFunctionConstantIndex {
        static let offsetXY = 0
        static let sourceUV0 = 1
        static let sourceUVScale0 = 2
        static let sourceRange = 3
    }

    private struct InputNv12DevicePipelineKey: Hashable {
        var variant: InputNv12DeviceKernelVariant
        var blendsWithAlpha: Bool
        var lumaOffsetX: UInt32
        var lumaOffsetY: UInt32
        var chromaOffsetX: UInt32
        var chromaOffsetY: UInt32
        var sourceU0: Float
        var sourceV0: Float
        var sourceUScale0: Float
        var sourceVScale0: Float
        var sourceRange: UInt32

        init(
            variant: InputNv12DeviceKernelVariant,
            blendsWithAlpha: Bool,
            lumaOffsetXY: SIMD2<UInt32>,
            chromaOffsetXY: SIMD2<UInt32>,
            sourceUV0: SIMD2<Float>,
            sourceUVScale0: SIMD2<Float>,
            sourceRange: InputNv12DeviceSourceRange
        ) {
            self.variant = variant
            self.blendsWithAlpha = blendsWithAlpha
            lumaOffsetX = lumaOffsetXY.x
            lumaOffsetY = lumaOffsetXY.y
            chromaOffsetX = chromaOffsetXY.x
            chromaOffsetY = chromaOffsetXY.y
            sourceU0 = sourceUV0.x
            sourceV0 = sourceUV0.y
            sourceUScale0 = sourceUVScale0.x
            sourceVScale0 = sourceUVScale0.y
            self.sourceRange = sourceRange.rawValue
        }
    }

    struct InputNv12DevicePipelines {
        var luma: MTLComputePipelineState
        var chroma: MTLComputePipelineState
    }

    private let device: MTLDevice
    private let library: MTLLibrary
    private let lock = NSLock()
    private var inputNv12DevicePipelinesBySpecialization: [InputNv12DevicePipelineKey: InputNv12DevicePipelines] = [:]

    init(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        self.library = library
    }

    func inputNv12DevicePipelines(
        variant: InputNv12DeviceKernelVariant,
        blendsWithAlpha: Bool = false,
        lumaOffsetXY: SIMD2<UInt32>,
        chromaOffsetXY: SIMD2<UInt32>,
        sourceUV0: SIMD2<Float>,
        sourceUVScale0: SIMD2<Float>,
        sourceRange: InputNv12DeviceSourceRange
    ) throws -> InputNv12DevicePipelines {
        let key = InputNv12DevicePipelineKey(
            variant: variant,
            blendsWithAlpha: blendsWithAlpha,
            lumaOffsetXY: lumaOffsetXY,
            chromaOffsetXY: chromaOffsetXY,
            sourceUV0: sourceUV0,
            sourceUVScale0: sourceUVScale0,
            sourceRange: sourceRange
        )

        lock.lock()
        if let pipelines = inputNv12DevicePipelinesBySpecialization[key] {
            lock.unlock()
            return pipelines
        }
        lock.unlock()

        let pipelines = InputNv12DevicePipelines(
            luma: try inputNv12DevicePipeline(
                functionName: blendsWithAlpha ? "\(variant.functionNameStem)AlphaLumaKernel" : variant.lumaFunctionName,
                offsetXY: lumaOffsetXY,
                sourceUV0: sourceUV0,
                sourceUVScale0: sourceUVScale0,
                sourceRange: sourceRange
            ),
            chroma: try inputNv12DevicePipeline(
                functionName: blendsWithAlpha ? "\(variant.functionNameStem)AlphaChromaKernel" : variant.chromaFunctionName,
                offsetXY: chromaOffsetXY,
                sourceUV0: sourceUV0,
                sourceUVScale0: sourceUVScale0,
                sourceRange: sourceRange
            )
        )

        lock.lock()
        inputNv12DevicePipelinesBySpecialization[key] = pipelines
        lock.unlock()
        return pipelines
    }

    private func inputNv12DevicePipeline(
        functionName: String,
        offsetXY: SIMD2<UInt32>,
        sourceUV0: SIMD2<Float>,
        sourceUVScale0: SIMD2<Float>,
        sourceRange: InputNv12DeviceSourceRange
    ) throws -> MTLComputePipelineState {
        var bakedOffsetXY = offsetXY
        var bakedSourceUV0 = sourceUV0
        var bakedSourceUVScale0 = sourceUVScale0
        var bakedSourceRange = sourceRange.rawValue
        let constantValues = MTLFunctionConstantValues()
        constantValues.setConstantValue(
            &bakedOffsetXY,
            type: .uint2,
            index: InputNv12DeviceFunctionConstantIndex.offsetXY
        )
        constantValues.setConstantValue(
            &bakedSourceUV0,
            type: .float2,
            index: InputNv12DeviceFunctionConstantIndex.sourceUV0
        )
        constantValues.setConstantValue(
            &bakedSourceUVScale0,
            type: .float2,
            index: InputNv12DeviceFunctionConstantIndex.sourceUVScale0
        )
        constantValues.setConstantValue(
            &bakedSourceRange,
            type: .uint,
            index: InputNv12DeviceFunctionConstantIndex.sourceRange
        )

        let function = try library.makeFunction(name: functionName, constantValues: constantValues)
        return try device.makeComputePipelineState(function: function)
    }
}
