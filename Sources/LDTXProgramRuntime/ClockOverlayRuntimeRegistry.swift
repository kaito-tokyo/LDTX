// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXProgramRendering
import LDTXVideoComposition
import Metal

/// Confined to its producer queue; never synchronized from the frame-render loop.
final class ClockOverlayRuntimeRegistry: @unchecked Sendable {
  private struct Entry {
    var runtime: ClockOverlayRuntime
    var generation: UUID
  }

  private struct Placement {
    var destinationRect: SIMD4<UInt32>
    var sourceRect: SIMD4<Float>
    var pixelWidth: Int
    var pixelHeight: Int
  }

  private let currentTimeProvider: any ClockCurrentTimeProviding
  private let renderer: MetalClockOverlayRenderer
  private var entriesByStepName: [String: Entry] = [:]
  private var textureStore = ProgramOverlayTextureStore()

  init(
    device: MTLDevice,
    currentTimeProvider: any ClockCurrentTimeProviding
  ) throws {
    self.currentTimeProvider = currentTimeProvider
    renderer = try MetalClockOverlayRenderer(device: device)
  }

  func synchronize(
    composite: CompositeProgramDefinition,
    outputWidth: Int,
    outputHeight: Int,
    textures: ProgramOverlayTextureStore? = nil
  ) {
    if let textures, textures !== textureStore {
      deactivateAll()
      textureStore = textures
    }
    var activeStepNames: Set<String> = []
    for step in composite.steps {
      guard case .clock(var component) = step.component else { continue }
      var nativeSize: SIMD2<Float>?
      if component.fontSize != nil, component.resolvedRTFD == nil {
        guard outputWidth > 0, outputHeight > 0,
          let size = renderer.naturalClockSize(for: component)
        else { continue }
        nativeSize = size
        component.destinationWidth *= size.x / Float(outputWidth)
        component.destinationHeight *= size.y / Float(outputHeight)
      }
      guard
        var placement = Self.placement(
          component: component,
          outputWidth: outputWidth,
          outputHeight: outputHeight
        )
      else { continue }
      // Rasterize at the authored font size. The compositor applies layer scale
      // to the whole retained image, including padding and outlines.
      if let nativeSize {
        placement.pixelWidth = Int(nativeSize.x)
        placement.pixelHeight = Int(nativeSize.y)
      }
      activeStepNames.insert(step.name)

      if let entry = entriesByStepName[step.name] {
        textureStore.place(
          step.name, generation: entry.generation,
          destination: placement.destinationRect, source: placement.sourceRect)
        entry.runtime.update(
          component: component,
          pixelWidth: placement.pixelWidth,
          pixelHeight: placement.pixelHeight
        )
        continue
      }

      let generation = UUID()
      textureStore.place(
        step.name, generation: generation,
        destination: placement.destinationRect, source: placement.sourceRect)
      let runtime = ClockOverlayRuntime(
        component: component,
        pixelWidth: placement.pixelWidth,
        pixelHeight: placement.pixelHeight,
        currentTimeProvider: currentTimeProvider,
        renderer: renderer,
        overlayDidChange: { [textureStore] texture in
          textureStore.publish(texture, name: step.name, generation: generation)
        }
      )
      entriesByStepName[step.name] = Entry(
        runtime: runtime,
        generation: generation
      )
      runtime.activate()
    }

    let removedStepNames = Set(entriesByStepName.keys).subtracting(activeStepNames)
    for stepName in removedStepNames {
      entriesByStepName.removeValue(forKey: stepName)?.runtime.deactivate()
    }
    textureStore.retain(activeStepNames)
  }

  func retainedTexture(forStepNamed stepName: String) -> RetainedTextureComponent? {
    textureStore.snapshot()[stepName]
  }

  func deactivateAll() {
    textureStore.retain([])
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
        origin: component.destinationX + min(component.destinationWidth, 0),
        intendedSize: pixelWidth,
        dimension: width
      ),
      let vertical = clippedAxis(
        origin: component.destinationY + min(component.destinationHeight, 0),
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
        component.destinationWidth < 0 ? 1 - horizontal.sourceStart : horizontal.sourceStart,
        component.destinationHeight < 0 ? 1 - vertical.sourceStart : vertical.sourceStart,
        component.destinationWidth < 0 ? 1 - horizontal.sourceEnd : horizontal.sourceEnd,
        component.destinationHeight < 0 ? 1 - vertical.sourceEnd : vertical.sourceEnd
      ),
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight
    )
  }

  private static func intendedSize(_ normalized: Float, dimension: Int) -> Int {
    guard normalized.isFinite, normalized != 0 else { return 0 }
    let pixels = min(abs(Double(normalized)) * Double(dimension), 16_384)
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
