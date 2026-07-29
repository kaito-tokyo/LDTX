// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXProgramRendering
import LDTXVideoComposition
import Metal

/// Render-queue-confined ownership for every Clock in one ProgramRuntime.
final class ClockOverlayRuntimeRegistry {
  private struct Entry {
    var destinationRect: SIMD4<UInt32>
    var sourceRect: SIMD4<Float>
    var runtime: ClockOverlayRuntime
  }

  private struct Placement {
    var destinationRect: SIMD4<UInt32>
    var sourceRect: SIMD4<Float>
    var pixelWidth: Int
    var pixelHeight: Int
  }

  private let updateRegistry: LowFrequencyUpdateRegistry
  private let currentTimeProvider: any ClockCurrentTimeProviding
  private let renderer: MetalClockOverlayRenderer
  private var entriesByStepName: [String: Entry] = [:]

  init(
    device: MTLDevice,
    updateRegistry: LowFrequencyUpdateRegistry,
    currentTimeProvider: any ClockCurrentTimeProviding
  ) throws {
    self.updateRegistry = updateRegistry
    self.currentTimeProvider = currentTimeProvider
    renderer = try MetalClockOverlayRenderer(device: device)
  }

  func synchronize(
    composite: CompositeProgramDefinition,
    outputWidth: Int,
    outputHeight: Int
  ) {
    var activeStepNames: Set<String> = []
    for step in composite.steps {
      guard case .clock(let component) = step.component else { continue }
      guard let placement = Self.placement(
        component: component,
        outputWidth: outputWidth,
        outputHeight: outputHeight
      ) else { continue }
      activeStepNames.insert(step.name)

      if var entry = entriesByStepName[step.name] {
        entry.destinationRect = placement.destinationRect
        entry.sourceRect = placement.sourceRect
        entry.runtime.update(
          component: component,
          pixelWidth: placement.pixelWidth,
          pixelHeight: placement.pixelHeight
        )
        entriesByStepName[step.name] = entry
        continue
      }

      let runtime = ClockOverlayRuntime(
        component: component,
        pixelWidth: placement.pixelWidth,
        pixelHeight: placement.pixelHeight,
        updateRegistry: updateRegistry,
        currentTimeProvider: currentTimeProvider,
        renderer: renderer
      )
      entriesByStepName[step.name] = Entry(
        destinationRect: placement.destinationRect,
        sourceRect: placement.sourceRect,
        runtime: runtime
      )
      runtime.activate()
    }

    let removedStepNames = Set(entriesByStepName.keys).subtracting(activeStepNames)
    for stepName in removedStepNames {
      entriesByStepName.removeValue(forKey: stepName)?.runtime.deactivate()
    }
  }

  func retainedTexture(forStepNamed stepName: String) -> RetainedTextureComponent? {
    guard let entry = entriesByStepName[stepName],
      let overlay = entry.runtime.retainedOverlay()
    else { return nil }
    return RetainedTextureComponent(
      colorTexture: overlay.colorTexture,
      alphaTexture: overlay.alphaTexture,
      destinationRect: entry.destinationRect,
      sourceRect: entry.sourceRect
    )
  }

  func deactivateAll() {
    let entries = entriesByStepName.values
    entriesByStepName.removeAll()
    for entry in entries {
      entry.runtime.deactivate()
    }
  }

  deinit {
    deactivateAll()
  }

  private static func placement(
    component: ClockComponent,
    outputWidth: Int,
    outputHeight: Int
  ) -> Placement? {
    let width = max(outputWidth, 0)
    let height = max(outputHeight, 0)
    guard width > 0, height > 0 else { return nil }
    let pixelWidth = intendedSize(component.destinationWidth, dimension: width)
    let pixelHeight = intendedSize(component.destinationHeight, dimension: height)
    guard pixelWidth > 0, pixelHeight > 0,
      let horizontal = clippedAxis(
        origin: component.destinationX,
        intendedSize: pixelWidth,
        dimension: width
      ),
      let vertical = clippedAxis(
        origin: component.destinationY,
        intendedSize: pixelHeight,
        dimension: height
      )
    else { return nil }
    return Placement(
      destinationRect: SIMD4<UInt32>(
        UInt32(horizontal.start),
        UInt32(vertical.start),
        UInt32(horizontal.end),
        UInt32(vertical.end)
      ),
      sourceRect: SIMD4<Float>(
        horizontal.sourceStart,
        vertical.sourceStart,
        horizontal.sourceEnd,
        vertical.sourceEnd
      ),
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight
    )
  }

  private static func intendedSize(_ normalized: Float, dimension: Int) -> Int {
    guard normalized.isFinite, normalized > 0 else { return 0 }
    let pixels = min(Double(normalized) * Double(dimension), 16_384)
    return Int(pixels.rounded(.down))
  }

  private static func clippedAxis(
    origin normalizedOrigin: Float,
    intendedSize: Int,
    dimension: Int
  ) -> (start: Int, end: Int, sourceStart: Float, sourceEnd: Float)? {
    guard normalizedOrigin.isFinite else { return nil }
    let unboundedOrigin = (Double(normalizedOrigin) * Double(dimension)).rounded(.down)
    let origin = Int(max(min(unboundedOrigin, Double(Int.max / 4)), Double(Int.min / 4)))
    let start = max(origin, 0)
    let end = min(origin + intendedSize, dimension)
    guard start < end else { return nil }
    return (
      start,
      end,
      Float(start - origin) / Float(intendedSize),
      Float(end - origin) / Float(intendedSize)
    )
  }
}
