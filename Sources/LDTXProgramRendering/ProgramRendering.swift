// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXVideoComposition
import simd

public extension CompositeProgramDefinition {
    func appendComponentCommands(
        to commands: inout [MetalVideoComponentCommand],
        worldWidth: Int,
        worldHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        source: MetalVideoSource? = nil,
        sourceForInputKey: (String) -> MetalVideoSource? = { _ in nil },
        colorRangeForInputKey: (String) -> CameraInputColorRangeOverride = { _ in .unspecified },
        destinationForStep: (CompositeProgramStep) -> InputDeviceDestination? = { _ in nil },
        retainedTextureForStep: (CompositeProgramStep) -> RetainedTextureComponent? = { _ in nil },
        timeSeconds: Float
    ) {
        commands.reserveCapacity(commands.count + steps.count)
        for step in steps.reversed() {
            var component = step.component
            if case .inputCameraDevice(var payload) = component,
               let destination = destinationForStep(step)
            {
                payload.destination = destination
                component = .inputCameraDevice(payload)
            }
            if case .clock = component,
               let retainedTexture = retainedTextureForStep(step) {
                commands.append(.retainedTexture(retainedTexture))
                continue
            }
            component.appendComponentCommands(
                to: &commands,
                worldWidth: worldWidth,
                worldHeight: worldHeight,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                source: sourceForInputKey(inputCameraDeviceMappingKey(for: step)) ?? source,
                colorRangeOverride: colorRangeForInputKey(inputCameraDeviceMappingKey(for: step)),
                timeSeconds: timeSeconds
            )
        }
    }

    func components(
        width: Int,
        height: Int,
        source: MetalVideoSource? = nil,
        sourcesByInputKey: [String: MetalVideoSource] = [:],
        colorRangesByInputKey: [String: CameraInputColorRangeOverride] = [:],
        timeSeconds: Float
    ) -> [any MetalVideoComponent] {
        components(
            worldWidth: width,
            worldHeight: height,
            outputWidth: width,
            outputHeight: height,
            source: source,
            sourcesByInputKey: sourcesByInputKey,
            colorRangesByInputKey: colorRangesByInputKey,
            timeSeconds: timeSeconds
        )
    }

    func components(
        worldWidth: Int,
        worldHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        source: MetalVideoSource? = nil,
        sourcesByInputKey: [String: MetalVideoSource] = [:],
        colorRangesByInputKey: [String: CameraInputColorRangeOverride] = [:],
        timeSeconds: Float
    ) -> [any MetalVideoComponent] {
        // Preserve the protobuf/UI step order and draw from the bottom up:
        // later steps are emitted first so earlier rows can layer on top.
        var components: [any MetalVideoComponent] = []
        components.reserveCapacity(steps.count)
        for step in steps.reversed() {
            let stepComponents = step.component.components(
                worldWidth: worldWidth,
                worldHeight: worldHeight,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                source: sourcesByInputKey[inputCameraDeviceMappingKey(for: step)] ?? source,
                colorRangeOverride: colorRangesByInputKey[inputCameraDeviceMappingKey(for: step)] ?? .unspecified,
                timeSeconds: timeSeconds
            )
            for component in stepComponents {
                components.append(component)
            }
        }
        return components
    }
}

public extension ClockComponent {
    func destinationRect(outputWidth: Int, outputHeight: Int) -> SIMD4<UInt32> {
        let width = UInt32(clamping: outputWidth)
        let height = UInt32(clamping: outputHeight)
        let x = destinationX.isFinite ? destinationX : 0
        let y = destinationY.isFinite ? destinationY : 0
        let destinationWidth = self.destinationWidth.isFinite ? self.destinationWidth : 0
        let destinationHeight = self.destinationHeight.isFinite ? self.destinationHeight : 0
        let x0 = clockPixelCoordinate(x, limit: width)
        let y0 = clockPixelCoordinate(y, limit: height)
        let x1 = clockPixelCoordinate(x + destinationWidth, limit: width)
        let y1 = clockPixelCoordinate(y + destinationHeight, limit: height)
        return SIMD4<UInt32>(
            x0,
            y0,
            max(x0, x1),
            max(y0, y1)
        )
    }

    private func clockPixelCoordinate(_ value: Float, limit: UInt32) -> UInt32 {
        let normalized = min(max(value, 0), 1)
        // Float(UInt32.max) rounds to 2^32. Convert through Int64 and use a
        // clamping integer conversion so malformed/extreme runtime dimensions
        // cannot trap while a Clock is being removed or synchronized.
        let scaled = Int64((normalized * Float(limit)).rounded(.down))
        return UInt32(clamping: scaled)
    }
}

public extension ProgramComponent {
    func appendComponentCommands(
        to commands: inout [MetalVideoComponentCommand],
        worldWidth: Int,
        worldHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        source: MetalVideoSource?,
        colorRangeOverride: CameraInputColorRangeOverride = .unspecified,
        timeSeconds: Float
    ) {
        switch self {
        case let .fillSolidColor(payload):
            commands.append(.solidColor(
                SolidColorComponent(
                    color: payload.color,
                    destinationRect: payload.clip.rect(
                        worldWidth: worldWidth,
                        worldHeight: worldHeight,
                        outputWidth: outputWidth,
                        outputHeight: outputHeight
                    )
                )
            ))
        case let .fillLinearGradient(payload):
            commands.append(.linearGradient(
                LinearGradientComponent(
                    start: payload.start,
                    end: payload.end,
                    startColor: payload.startColor,
                    endColor: payload.endColor,
                    destinationRect: payload.clip.rect(
                        worldWidth: worldWidth,
                        worldHeight: worldHeight,
                        outputWidth: outputWidth,
                        outputHeight: outputHeight
                    )
                )
            ))
        case let .fillRadialGradient(payload):
            commands.append(.radialGradient(
                RadialGradientComponent(
                    center: payload.center,
                    innerRadius: payload.innerRadius,
                    outerRadius: payload.outerRadius,
                    innerColor: payload.innerColor,
                    outerColor: payload.outerColor,
                    destinationRect: payload.clip.rect(
                        worldWidth: worldWidth,
                        worldHeight: worldHeight,
                        outputWidth: outputWidth,
                        outputHeight: outputHeight
                    )
                )
            ))
        case let .fillConicGradient(payload):
            commands.append(.conicGradient(
                ConicGradientComponent(
                    center: payload.center,
                    startAngleRadians: payload.startAngleRadians,
                    startColor: payload.startColor,
                    endColor: payload.endColor,
                    destinationRect: payload.clip.rect(
                        worldWidth: worldWidth,
                        worldHeight: worldHeight,
                        outputWidth: outputWidth,
                        outputHeight: outputHeight
                    )
                )
            ))
        case let .inputCameraDevice(payload):
            guard let source else {
                return
            }
            if source.contentKind == .dummy {
                commands.append(.solidColor(SolidColorComponent(
                    color: SIMD4<Float>(0, 0, 0, source.hasAlphaMask ? 0 : 1),
                    destinationRect: scaledPixelRect(
                        payload.destinationRect(width: worldWidth, height: worldHeight),
                        worldWidth: worldWidth,
                        worldHeight: worldHeight,
                        outputWidth: outputWidth,
                        outputHeight: outputHeight
                    )
                )))
                return
            }
            commands.append(.cameraInput(
                CameraInputComponent(
                    source: source,
                    destinationRect: scaledPixelRect(
                        payload.destinationRect(width: worldWidth, height: worldHeight),
                        worldWidth: worldWidth,
                        worldHeight: worldHeight,
                        outputWidth: outputWidth,
                        outputHeight: outputHeight
                    ),
                    sourceRect: payload.sourceRect(width: worldWidth, height: worldHeight),
                    colorRangeOverride: colorRangeOverride
                )
            ))
        case .clock:
            // Clock commands are supplied by retainedTextureForStep after the
            // runtime has produced its first retained Metal texture. Until
            // then, preserve the underlying composition without stand-in pixels.
            break
        case .testPattern:
            commands.append(.testPattern(
                TestPatternComponent(
                    timeSeconds: timeSeconds,
                    destinationRect: SIMD4<UInt32>(
                        0,
                        0,
                        UInt32(max(outputWidth, 0)),
                        UInt32(max(outputHeight, 0))
                    )
                )
            ))
        }
    }

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
        colorRangeOverride: CameraInputColorRangeOverride = .unspecified,
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
                    ),
                    colorRangeOverride: colorRangeOverride
                )
            } else {
                []
            }
        case .clock:
            // Clock is rendered through its retained-texture runtime path.
            []
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
