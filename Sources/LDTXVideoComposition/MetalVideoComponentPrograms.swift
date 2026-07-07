// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import simd

public enum MetalVideoComponentPrograms {
    public static func fillSolidColor(
        width: Int,
        height: Int,
        color: SIMD4<Float> = SIMD4<Float>(0.95, 0.20, 0.18, 1),
        clip: SIMD4<UInt32>? = nil
    ) -> [any MetalVideoComponent] {
        let w = UInt32(max(width, 0))
        let h = UInt32(max(height, 0))
        return [
            SolidColorComponent(
                color: color,
                destinationRect: clip ?? SIMD4<UInt32>(0, 0, w, h)
            )
        ]
    }

    public static func fillLinearGradient(
        width: Int,
        height: Int,
        start: SIMD2<Float> = SIMD2<Float>(0, 0),
        end: SIMD2<Float> = SIMD2<Float>(1, 1),
        startColor: SIMD4<Float> = SIMD4<Float>(0.10, 0.72, 0.95, 1),
        endColor: SIMD4<Float> = SIMD4<Float>(0.08, 0.16, 0.50, 1),
        clip: SIMD4<UInt32>? = nil
    ) -> [any MetalVideoComponent] {
        let w = UInt32(max(width, 0))
        let h = UInt32(max(height, 0))
        return [
            LinearGradientComponent(
                start: start,
                end: end,
                startColor: startColor,
                endColor: endColor,
                destinationRect: clip ?? SIMD4<UInt32>(0, 0, w, h)
            )
        ]
    }

    public static func fillRadialGradient(
        width: Int,
        height: Int,
        center: SIMD2<Float> = SIMD2<Float>(0.5, 0.5),
        innerRadius: Float = 0,
        outerRadius: Float = 0.72,
        innerColor: SIMD4<Float> = SIMD4<Float>(0.96, 0.96, 0.98, 1),
        outerColor: SIMD4<Float> = SIMD4<Float>(0.42, 0.10, 0.80, 1),
        clip: SIMD4<UInt32>? = nil
    ) -> [any MetalVideoComponent] {
        let w = UInt32(max(width, 0))
        let h = UInt32(max(height, 0))
        return [
            RadialGradientComponent(
                center: center,
                innerRadius: innerRadius,
                outerRadius: outerRadius,
                innerColor: innerColor,
                outerColor: outerColor,
                destinationRect: clip ?? SIMD4<UInt32>(0, 0, w, h)
            )
        ]
    }

    public static func fillConicGradient(
        width: Int,
        height: Int,
        center: SIMD2<Float> = SIMD2<Float>(0.5, 0.5),
        startAngleRadians: Float = 0,
        startColor: SIMD4<Float> = SIMD4<Float>(0.95, 0.18, 0.60, 1),
        endColor: SIMD4<Float> = SIMD4<Float>(0.12, 0.75, 0.90, 1),
        clip: SIMD4<UInt32>? = nil
    ) -> [any MetalVideoComponent] {
        let w = UInt32(max(width, 0))
        let h = UInt32(max(height, 0))
        return [
            ConicGradientComponent(
                center: center,
                startAngleRadians: startAngleRadians,
                startColor: startColor,
                endColor: endColor,
                destinationRect: clip ?? SIMD4<UInt32>(0, 0, w, h)
            )
        ]
    }

    public static func inputCameraDevice(
        width: Int,
        height: Int,
        source: MetalVideoSource,
        sourceRect: SIMD4<Float> = SIMD4<Float>(0, 0, 1, 1),
        destinationRect: SIMD4<UInt32>? = nil,
        colorRangeOverride: CameraInputColorRangeOverride = .unspecified
    ) -> [any MetalVideoComponent] {
        let w = UInt32(max(width, 0))
        let h = UInt32(max(height, 0))
        return [
            CameraInputComponent(
                source: source,
                destinationRect: destinationRect ?? SIMD4<UInt32>(0, 0, w, h),
                sourceRect: sourceRect,
                colorRangeOverride: colorRangeOverride
            )
        ]
    }

    public static func testPattern(
        width: Int,
        height: Int,
        timeSeconds: Float
    ) -> [any MetalVideoComponent] {
        let w = UInt32(max(width, 0))
        let h = UInt32(max(height, 0))
        return [
            TestPatternComponent(
                timeSeconds: timeSeconds,
                destinationRect: SIMD4<UInt32>(0, 0, w, h)
            )
        ]
    }
}
