// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXVideoComposition
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
        // Crop is part of the input-device pipeline, so it intentionally
        // specializes the Metal function. Destination placement is a
        // per-command buffer argument and must never be added here.
        static let sourceUV0 = 0
        static let sourceUVScale0 = 1
        static let sourceRange = 2
    }

    private struct InputNv12DevicePipelineKey: Hashable {
        var variant: InputNv12DeviceKernelVariant
        var alphaMaskKind: MetalVideoAlphaMaskKind?
        var sourceU0: Int
        var sourceV0: Int
        var sourceUScale0: Int
        var sourceVScale0: Int
        var sourceRange: UInt32

        init(
            variant: InputNv12DeviceKernelVariant,
            alphaMaskKind: MetalVideoAlphaMaskKind?,
            sourceUV0: SIMD2<Float>,
            sourceUVScale0: SIMD2<Float>,
            sourceRange: InputNv12DeviceSourceRange
        ) {
            self.variant = variant
            self.alphaMaskKind = alphaMaskKind
            sourceU0 = Self.quantize(sourceUV0.x)
            sourceV0 = Self.quantize(sourceUV0.y)
            sourceUScale0 = Self.quantize(sourceUVScale0.x)
            sourceVScale0 = Self.quantize(sourceUVScale0.y)
            self.sourceRange = sourceRange.rawValue
        }

        var sourceUV0: SIMD2<Float> {
            SIMD2<Float>(Self.dequantize(sourceU0), Self.dequantize(sourceV0))
        }

        var sourceUVScale0: SIMD2<Float> {
            SIMD2<Float>(Self.dequantize(sourceUScale0), Self.dequantize(sourceVScale0))
        }

        private static let cropQuantizationScale: Float = 1_024
        private static let maximumQuantizedCropCoordinate: Float = 1_000

        private static func quantize(_ value: Float) -> Int {
            let finiteValue = value.isFinite ? value : 0
            let clampedValue = min(
                max(finiteValue, -maximumQuantizedCropCoordinate),
                maximumQuantizedCropCoordinate
            )
            return Int((clampedValue * cropQuantizationScale).rounded())
        }

        private static func dequantize(_ value: Int) -> Float {
            Float(value) / cropQuantizationScale
        }
    }

    struct InputNv12DevicePipelines {
        var luma: MTLComputePipelineState
        var chroma: MTLComputePipelineState
    }

    private struct CachedInputNv12DevicePipelines {
        var pipelines: InputNv12DevicePipelines
        var lastUse: UInt64
    }

    private static let maximumInputNv12DevicePipelineSpecializations = 128

    private let device: MTLDevice
    private let library: MTLLibrary
    private let lock = NSLock()
    private var inputNv12DevicePipelinesBySpecialization: [
        InputNv12DevicePipelineKey: CachedInputNv12DevicePipelines
    ] = [:]
    private var inputNv12DevicePipelineUseCounter: UInt64 = 0

    var inputNv12DevicePipelineSpecializationCount: Int {
        lock.withLock { inputNv12DevicePipelinesBySpecialization.count }
    }

    init(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        self.library = library
    }

    func inputNv12DevicePipelines(
        variant: InputNv12DeviceKernelVariant,
        alphaMaskKind: MetalVideoAlphaMaskKind? = nil,
        sourceUV0: SIMD2<Float>,
        sourceUVScale0: SIMD2<Float>,
        sourceRange: InputNv12DeviceSourceRange
    ) throws -> InputNv12DevicePipelines {
        let key = InputNv12DevicePipelineKey(
            variant: variant,
            alphaMaskKind: alphaMaskKind,
            sourceUV0: sourceUV0,
            sourceUVScale0: sourceUVScale0,
            sourceRange: sourceRange
        )

        lock.lock()
        if var cached = inputNv12DevicePipelinesBySpecialization[key] {
            inputNv12DevicePipelineUseCounter &+= 1
            cached.lastUse = inputNv12DevicePipelineUseCounter
            inputNv12DevicePipelinesBySpecialization[key] = cached
            lock.unlock()
            return cached.pipelines
        }
        lock.unlock()

        let pipelines = InputNv12DevicePipelines(
            luma: try inputNv12DevicePipeline(
                functionName: inputNv12DeviceFunctionName(
                    variant: variant,
                    alphaMaskKind: alphaMaskKind,
                    planeSuffix: "LumaKernel"
                ),
                sourceUV0: key.sourceUV0,
                sourceUVScale0: key.sourceUVScale0,
                sourceRange: sourceRange
            ),
            chroma: try inputNv12DevicePipeline(
                functionName: inputNv12DeviceFunctionName(
                    variant: variant,
                    alphaMaskKind: alphaMaskKind,
                    planeSuffix: "ChromaKernel"
                ),
                sourceUV0: key.sourceUV0,
                sourceUVScale0: key.sourceUVScale0,
                sourceRange: sourceRange
            )
        )

        lock.lock()
        if var cached = inputNv12DevicePipelinesBySpecialization[key] {
            inputNv12DevicePipelineUseCounter &+= 1
            cached.lastUse = inputNv12DevicePipelineUseCounter
            inputNv12DevicePipelinesBySpecialization[key] = cached
            lock.unlock()
            return cached.pipelines
        }
        if inputNv12DevicePipelinesBySpecialization.count
            >= Self.maximumInputNv12DevicePipelineSpecializations,
            let leastRecentlyUsedKey = inputNv12DevicePipelinesBySpecialization.min(
                by: { $0.value.lastUse < $1.value.lastUse }
            )?.key
        {
            inputNv12DevicePipelinesBySpecialization.removeValue(forKey: leastRecentlyUsedKey)
        }
        inputNv12DevicePipelineUseCounter &+= 1
        inputNv12DevicePipelinesBySpecialization[key] = CachedInputNv12DevicePipelines(
            pipelines: pipelines,
            lastUse: inputNv12DevicePipelineUseCounter
        )
        lock.unlock()
        return pipelines
    }

    private func inputNv12DeviceFunctionName(
        variant: InputNv12DeviceKernelVariant,
        alphaMaskKind: MetalVideoAlphaMaskKind?,
        planeSuffix: String
    ) -> String {
        switch alphaMaskKind {
        case .none:
            "\(variant.functionNameStem)\(planeSuffix)"
        case .oneComponent8:
            "\(variant.functionNameStem)Alpha\(planeSuffix)"
        case .rawFloat16:
            "\(variant.functionNameStem)RawMask\(planeSuffix)"
        }
    }

    private func inputNv12DevicePipeline(
        functionName: String,
        sourceUV0: SIMD2<Float>,
        sourceUVScale0: SIMD2<Float>,
        sourceRange: InputNv12DeviceSourceRange
    ) throws -> MTLComputePipelineState {
        var bakedSourceUV0 = sourceUV0
        var bakedSourceUVScale0 = sourceUVScale0
        var bakedSourceRange = sourceRange.rawValue
        let constantValues = MTLFunctionConstantValues()
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
