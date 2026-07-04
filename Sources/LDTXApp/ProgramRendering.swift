// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXMedia
import LDTXProgram
import simd

extension ProgramDefinition {
    func components(
        width: Int,
        height: Int,
        composite: CompositeProgramDefinition,
        source: MetalVideoSource? = nil,
        sourcesByInputKey: [String: MetalVideoSource] = [:],
        timeSeconds: Float
    ) -> [any MetalVideoComponent] {
        components(
            worldWidth: width,
            worldHeight: height,
            outputWidth: width,
            outputHeight: height,
            composite: composite,
            source: source,
            sourcesByInputKey: sourcesByInputKey,
            timeSeconds: timeSeconds
        )
    }

    func components(
        worldWidth: Int,
        worldHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        composite: CompositeProgramDefinition,
        source: MetalVideoSource? = nil,
        sourcesByInputKey: [String: MetalVideoSource] = [:],
        timeSeconds: Float
    ) -> [any MetalVideoComponent] {
        switch self {
        case .fillSolidColor:
            ProgramComponent.defaultComponent(for: .fillSolidColor).components(
                worldWidth: worldWidth,
                worldHeight: worldHeight,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                source: source,
                timeSeconds: timeSeconds
            )
        case .fillLinearGradient:
            ProgramComponent.defaultComponent(for: .fillLinearGradient).components(
                worldWidth: worldWidth,
                worldHeight: worldHeight,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                source: source,
                timeSeconds: timeSeconds
            )
        case .fillRadialGradient:
            ProgramComponent.defaultComponent(for: .fillRadialGradient).components(
                worldWidth: worldWidth,
                worldHeight: worldHeight,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                source: source,
                timeSeconds: timeSeconds
            )
        case .fillConicGradient:
            ProgramComponent.defaultComponent(for: .fillConicGradient).components(
                worldWidth: worldWidth,
                worldHeight: worldHeight,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                source: source,
                timeSeconds: timeSeconds
            )
        case .inputCameraDevice:
            ProgramComponent.defaultComponent(for: .inputCameraDevice).components(
                worldWidth: worldWidth,
                worldHeight: worldHeight,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                source: sourcesByInputKey[BuiltInProgramDefinition.inputCameraDevice.rawValue] ?? source,
                timeSeconds: timeSeconds
            )
        case .testPattern:
            ProgramComponent.defaultComponent(for: .testPattern).components(
                worldWidth: worldWidth,
                worldHeight: worldHeight,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                source: source,
                timeSeconds: timeSeconds
            )
        case .composite:
            composite.components(
                worldWidth: worldWidth,
                worldHeight: worldHeight,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                source: source,
                sourcesByInputKey: sourcesByInputKey,
                timeSeconds: timeSeconds
            )
        }
    }
}

extension CompositeProgramDefinition {
    func components(
        width: Int,
        height: Int,
        source: MetalVideoSource?,
        sourcesByInputKey: [String: MetalVideoSource] = [:],
        timeSeconds: Float
    ) -> [any MetalVideoComponent] {
        components(
            worldWidth: width,
            worldHeight: height,
            outputWidth: width,
            outputHeight: height,
            source: source,
            sourcesByInputKey: sourcesByInputKey,
            timeSeconds: timeSeconds
        )
    }

    func components(
        worldWidth: Int,
        worldHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        source: MetalVideoSource?,
        sourcesByInputKey: [String: MetalVideoSource] = [:],
        timeSeconds: Float
    ) -> [any MetalVideoComponent] {
        steps.flatMap { step in
            step.component.components(
                worldWidth: worldWidth,
                worldHeight: worldHeight,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                source: sourcesByInputKey[inputCameraDeviceMappingKey(for: step)] ?? source,
                timeSeconds: timeSeconds
            )
        }
    }
}

extension ProgramComponent {
    func components(
        width: Int,
        height: Int,
        source: MetalVideoSource?,
        timeSeconds: Float
    ) -> [any MetalVideoComponent] {
        components(
            worldWidth: width,
            worldHeight: height,
            outputWidth: width,
            outputHeight: height,
            source: source,
            timeSeconds: timeSeconds
        )
    }

    func components(
        worldWidth: Int,
        worldHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        source: MetalVideoSource?,
        timeSeconds: Float
    ) -> [any MetalVideoComponent] {
        switch self {
        case let .fillSolidColor(payload):
            MetalVideoComponentPrograms.fillSolidColor(
                width: outputWidth,
                height: outputHeight,
                color: payload.color,
                clip: payload.clip.rect(
                    worldWidth: worldWidth,
                    worldHeight: worldHeight,
                    outputWidth: outputWidth,
                    outputHeight: outputHeight
                )
            )
        case let .fillLinearGradient(payload):
            MetalVideoComponentPrograms.fillLinearGradient(
                width: outputWidth,
                height: outputHeight,
                start: payload.start,
                end: payload.end,
                startColor: payload.startColor,
                endColor: payload.endColor,
                clip: payload.clip.rect(
                    worldWidth: worldWidth,
                    worldHeight: worldHeight,
                    outputWidth: outputWidth,
                    outputHeight: outputHeight
                )
            )
        case let .fillRadialGradient(payload):
            MetalVideoComponentPrograms.fillRadialGradient(
                width: outputWidth,
                height: outputHeight,
                center: payload.center,
                innerRadius: payload.innerRadius,
                outerRadius: payload.outerRadius,
                innerColor: payload.innerColor,
                outerColor: payload.outerColor,
                clip: payload.clip.rect(
                    worldWidth: worldWidth,
                    worldHeight: worldHeight,
                    outputWidth: outputWidth,
                    outputHeight: outputHeight
                )
            )
        case let .fillConicGradient(payload):
            MetalVideoComponentPrograms.fillConicGradient(
                width: outputWidth,
                height: outputHeight,
                center: payload.center,
                startAngleRadians: payload.startAngleRadians,
                startColor: payload.startColor,
                endColor: payload.endColor,
                clip: payload.clip.rect(
                    worldWidth: worldWidth,
                    worldHeight: worldHeight,
                    outputWidth: outputWidth,
                    outputHeight: outputHeight
                )
            )
        case let .inputCameraDevice(payload):
            if let source {
                MetalVideoComponentPrograms.inputCameraDevice(
                    width: outputWidth,
                    height: outputHeight,
                    source: source,
                    sourceRect: payload.sourceRect(width: worldWidth, height: worldHeight),
                    destinationRect: scaledPixelRect(
                        payload.destinationRect(width: worldWidth, height: worldHeight),
                        worldWidth: worldWidth,
                        worldHeight: worldHeight,
                        outputWidth: outputWidth,
                        outputHeight: outputHeight
                    )
                )
            } else {
                []
            }
        case .testPattern:
            MetalVideoComponentPrograms.testPattern(
                width: outputWidth,
                height: outputHeight,
                timeSeconds: timeSeconds
            )
        }
    }
}

private func scaledPixelRect(
    _ rect: SIMD4<UInt32>,
    worldWidth: Int,
    worldHeight: Int,
    outputWidth: Int,
    outputHeight: Int
) -> SIMD4<UInt32> {
    let scaleX = Float(max(outputWidth, 1)) / Float(max(worldWidth, 1))
    let scaleY = Float(max(outputHeight, 1)) / Float(max(worldHeight, 1))
    let x0 = scaledCoordinate(rect.x, scale: scaleX, limit: outputWidth)
    let y0 = scaledCoordinate(rect.y, scale: scaleY, limit: outputHeight)
    let x1 = max(x0, scaledCoordinate(rect.z, scale: scaleX, limit: outputWidth))
    let y1 = max(y0, scaledCoordinate(rect.w, scale: scaleY, limit: outputHeight))
    return SIMD4<UInt32>(x0, y0, x1, y1)
}

private func scaledCoordinate(_ value: UInt32, scale: Float, limit: Int) -> UInt32 {
    let scaled = Int((Float(value) * scale).rounded(.down))
    return UInt32(min(max(scaled, 0), max(limit, 0)))
}

private extension FillSolidColorComponent {
    var color: SIMD4<Float> {
        SIMD4<Float>(red, green, blue, alpha)
    }
}

private extension FillLinearGradientComponent {
    var start: SIMD2<Float> {
        SIMD2<Float>(startX, startY)
    }

    var end: SIMD2<Float> {
        SIMD2<Float>(endX, endY)
    }

    var startColor: SIMD4<Float> {
        SIMD4<Float>(startRed, startGreen, startBlue, startAlpha)
    }

    var endColor: SIMD4<Float> {
        SIMD4<Float>(endRed, endGreen, endBlue, endAlpha)
    }
}

private extension FillRadialGradientComponent {
    var center: SIMD2<Float> {
        SIMD2<Float>(centerX, centerY)
    }

    var innerColor: SIMD4<Float> {
        SIMD4<Float>(innerRed, innerGreen, innerBlue, innerAlpha)
    }

    var outerColor: SIMD4<Float> {
        SIMD4<Float>(outerRed, outerGreen, outerBlue, outerAlpha)
    }
}

private extension FillConicGradientComponent {
    var center: SIMD2<Float> {
        SIMD2<Float>(centerX, centerY)
    }

    var startColor: SIMD4<Float> {
        SIMD4<Float>(startRed, startGreen, startBlue, startAlpha)
    }

    var endColor: SIMD4<Float> {
        SIMD4<Float>(endRed, endGreen, endBlue, endAlpha)
    }
}

private extension FillClip {
    func rect(width canvasWidth: Int, height canvasHeight: Int) -> SIMD4<UInt32> {
        let canvasWidth = max(canvasWidth, 0)
        let canvasHeight = max(canvasHeight, 0)
        let x0 = clippedPixel(left, limit: canvasWidth)
        let x1 = max(x0, canvasWidth - clippedPixel(right, limit: canvasWidth))
        let y0 = clippedPixel(top, limit: canvasHeight)
        let y1 = max(y0, canvasHeight - clippedPixel(bottom, limit: canvasHeight))
        return SIMD4<UInt32>(UInt32(x0), UInt32(y0), UInt32(x1), UInt32(y1))
    }

    func rect(
        worldWidth: Int,
        worldHeight: Int,
        outputWidth: Int,
        outputHeight: Int
    ) -> SIMD4<UInt32> {
        scaledPixelRect(
            rect(width: worldWidth, height: worldHeight),
            worldWidth: worldWidth,
            worldHeight: worldHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight
        )
    }

    func clippedPixel(_ value: Float, limit: Int) -> Int {
        min(max(Int(value.rounded(.down)), 0), limit)
    }
}

private extension InputDeviceComponent {
    func sourceRect(width: Int, height: Int) -> SIMD4<Float> {
        let canvasWidth = Float(max(width, 1))
        let canvasHeight = Float(max(height, 1))
        let source = sourceUVRect()
        let visibleDestination = visibleDestinationFractions(
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight
        )
        return SIMD4<Float>(
            source.x + source.z * visibleDestination.x,
            source.y + source.w * visibleDestination.y,
            source.z * visibleDestination.z,
            source.w * visibleDestination.w
        )
    }

    func destinationRect(width: Int, height: Int) -> SIMD4<UInt32> {
        let canvasWidth = Float(max(width, 1))
        let canvasHeight = Float(max(height, 1))
        let rect = clippedDestinationPixelRect(
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight
        )
        let x0 = UInt32(max(Int(rect.x.rounded(.down)), 0))
        let y0 = UInt32(max(Int(rect.y.rounded(.down)), 0))
        let x1 = UInt32(max(Int((rect.x + rect.z).rounded(.down)), Int(x0)))
        let y1 = UInt32(max(Int((rect.y + rect.w).rounded(.down)), Int(y0)))
        return SIMD4<UInt32>(x0, y0, x1, y1)
    }

    func sourceUVRect() -> SIMD4<Float> {
        let top = percentToUnit(sourceCropTop)
        let right = percentToUnit(sourceCropRight)
        let bottom = percentToUnit(sourceCropBottom)
        let left = percentToUnit(sourceCropLeft)
        return SIMD4<Float>(
            left,
            top,
            max(0, 1 - left - right),
            max(0, 1 - top - bottom)
        )
    }

    func unclippedDestinationPixelRect(
        canvasWidth: Float,
        canvasHeight: Float
    ) -> SIMD4<Float> {
        let source = sourceUVRect()
        let scale = max(destinationScale, 0)
        let rectWidth = canvasWidth * source.z * scale
        let rectHeight = canvasHeight * source.w * scale
        return SIMD4<Float>(destinationX, destinationY, rectWidth, rectHeight)
    }

    func clippedDestinationPixelRect(
        canvasWidth: Float,
        canvasHeight: Float
    ) -> SIMD4<Float> {
        let rect = unclippedDestinationPixelRect(
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight
        )
        let x0 = min(max(rect.x, 0), canvasWidth)
        let y0 = min(max(rect.y, 0), canvasHeight)
        let x1 = min(max(rect.x + rect.z, x0), canvasWidth)
        let y1 = min(max(rect.y + rect.w, y0), canvasHeight)
        return SIMD4<Float>(x0, y0, x1 - x0, y1 - y0)
    }

    func visibleDestinationFractions(
        canvasWidth: Float,
        canvasHeight: Float
    ) -> SIMD4<Float> {
        let full = unclippedDestinationPixelRect(
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight
        )
        let clipped = clippedDestinationPixelRect(
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight
        )
        guard full.z > 0, full.w > 0, clipped.z > 0, clipped.w > 0 else {
            return SIMD4<Float>(0, 0, 0, 0)
        }
        return SIMD4<Float>(
            (clipped.x - full.x) / full.z,
            (clipped.y - full.y) / full.w,
            clipped.z / full.z,
            clipped.w / full.w
        )
    }

    func percentToUnit(_ value: Float) -> Float {
        min(max(value, 0), 100) / 100
    }
}
