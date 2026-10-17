// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import Metal
import OSLog

/// Owns overlay generation independently of frame rendering and its consumers.
public final class ProgramOverlayProducer: @unchecked Sendable {
  public let textures = ProgramOverlayTextureStore()
  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.overlay-producer", qos: .userInitiated)
  private final class State: @unchecked Sendable {
    var registry: ClockOverlayRuntimeRegistry?
    var failedConfiguration: InitializationConfiguration?
    let factory: @Sendable () throws -> ClockOverlayRuntimeRegistry
    init(factory: @escaping @Sendable () throws -> ClockOverlayRuntimeRegistry) {
      self.factory = factory
    }
  }
  private let state: State

  public convenience init(
    currentTimeProvider: any ClockCurrentTimeProviding = SystemClockCurrentTimeProvider()
  ) {
    self.init(registryFactory: {
      guard let device = MTLCreateSystemDefaultDevice() else {
        throw MetalClockOverlayRendererError.textureCreationFailed
      }
      return try ClockOverlayRuntimeRegistry(
        device: device, currentTimeProvider: currentTimeProvider)
    })
  }

  init(registryFactory: @escaping @Sendable () throws -> ClockOverlayRuntimeRegistry) {
    state = State(factory: registryFactory)
  }

  public func update(
    configuration: ProgramRuntimeConfiguration, preferences: ProgramPreferences = .init()
  ) {
    let composite = compositeApplyingVideoLayerVisibility(
      configuration.composite, preferences: preferences,
      programName: configuration.videoLayerProgramName)
    queue.async { [state, textures] in
      let hasOverlays = composite.steps.contains {
        if case .clock = $0.component { return true }
        return false
      }
      guard hasOverlays else {
        state.registry?.deactivateAll()
        textures.retain([])
        state.failedConfiguration = nil
        return
      }
      let key = InitializationConfiguration(
        steps: composite.steps.compactMap {
          guard case .clock(let component) = $0.component else { return nil }
          return InitializationConfiguration.Step(name: $0.name, component: component)
        }, outputWidth: configuration.outputWidth, outputHeight: configuration.outputHeight)
      if state.registry == nil {
        guard state.failedConfiguration != key else { return }
        do {
          state.registry = try state.factory()
          state.failedConfiguration = nil
        } catch {
          state.failedConfiguration = key
          Logger(subsystem: "tokyo.kaito.ldtx", category: "overlay-producer").error(
            "Overlay preparation failed: \(error.localizedDescription, privacy: .public)")
          return
        }
      }
      state.registry?.synchronize(
        composite: composite, outputWidth: configuration.outputWidth,
        outputHeight: configuration.outputHeight, textures: textures)
    }
  }

  public func stop() {
    queue.async { [state, textures] in
      state.registry?.deactivateAll()
      textures.retain([])
      state.failedConfiguration = nil
    }
  }

  deinit {
    queue.async { [state, textures] in
      state.registry?.deactivateAll()
      textures.retain([])
    }
  }

  private struct InitializationConfiguration: Equatable {
    struct Step: Equatable {
      var name: String
      var scalarBitPatterns: [UInt32]
      var showsSeconds: Bool
      var uses24HourTime: Bool
      var showsDate: Bool
      var usesSystemTimeZone: Bool
      var utcOffsetMinutes: Int32
      var resolvedText: String?
      var background: String
      var outlineDescriptions: [String]

      init(name: String, component: ClockComponent) {
        self.name = name
        scalarBitPatterns = [
          component.destinationX.bitPattern,
          component.destinationY.bitPattern,
          component.destinationWidth.bitPattern,
          component.destinationHeight.bitPattern,
          component.foregroundRed.bitPattern,
          component.foregroundGreen.bitPattern,
          component.foregroundBlue.bitPattern,
          component.foregroundAlpha.bitPattern,
          component.backgroundRed.bitPattern,
          component.backgroundGreen.bitPattern,
          component.backgroundBlue.bitPattern,
          component.backgroundAlpha.bitPattern,
        ]
        showsSeconds = component.showsSeconds
        uses24HourTime = component.uses24HourTime
        showsDate = component.showsDate
        usesSystemTimeZone = component.usesSystemTimeZone
        utcOffsetMinutes = component.utcOffsetMinutes
        resolvedText = component.resolvedText
        background = component.background
        outlineDescriptions = component.outlines.map { "\($0.thickness.bitPattern):\($0.color)" }
      }
    }

    var steps: [Step]
    var outputWidth: Int
    var outputHeight: Int
  }

}
