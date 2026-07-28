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
    var runtime: ClockOverlayRuntime
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
      let destinationRect = component.destinationRect(
        outputWidth: outputWidth,
        outputHeight: outputHeight
      )
      let pixelWidth = Int(destinationRect.z - destinationRect.x)
      let pixelHeight = Int(destinationRect.w - destinationRect.y)
      guard pixelWidth > 0, pixelHeight > 0 else { continue }
      activeStepNames.insert(step.name)

      if var entry = entriesByStepName[step.name] {
        entry.destinationRect = destinationRect
        entry.runtime.update(
          component: component,
          pixelWidth: pixelWidth,
          pixelHeight: pixelHeight
        )
        entriesByStepName[step.name] = entry
        continue
      }

      let runtime = ClockOverlayRuntime(
        component: component,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        updateRegistry: updateRegistry,
        currentTimeProvider: currentTimeProvider,
        renderer: renderer
      )
      entriesByStepName[step.name] = Entry(
        destinationRect: destinationRect,
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
      destinationRect: entry.destinationRect
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
}
