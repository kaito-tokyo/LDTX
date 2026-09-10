// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import CryptoKit
import Foundation
import LDTXProgram
import Metal
import Testing

@testable import LDTXProgramRuntime

@Suite(.serialized)
struct ClockOverlayRuntimeSystemTestSuite {
  @Test func retainedClockTextureRejectsInvalidCompositorContracts() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let validColor = try makeTexture(
      device: device,
      pixelFormat: .b5g6r5Unorm,
      width: 16,
      height: 16,
      usage: .shaderRead
    )
    let validAlpha = try makeTexture(
      device: device,
      pixelFormat: .r8Unorm,
      width: 16,
      height: 16,
      usage: .shaderRead
    )

    assertNoThrow(
      try ClockOverlayTexture(colorTexture: validColor, alphaTexture: validAlpha)
    )
    assertThrowsError(
      try ClockOverlayTexture(
        colorTexture: makeTexture(
          device: device,
          pixelFormat: .rgba8Unorm,
          width: 16,
          height: 16,
          usage: .shaderRead
        )
      )
    ) { error in
      assertEqual(error as? ClockOverlayTextureError, .colorTextureMustBeRGB565)
    }
    assertThrowsError(
      try ClockOverlayTexture(
        colorTexture: makeTexture(
          device: device,
          pixelFormat: .b5g6r5Unorm,
          width: 16,
          height: 16,
          usage: .renderTarget
        )
      )
    ) { error in
      assertEqual(error as? ClockOverlayTextureError, .colorTextureMustBeSampleable2D)
    }
    assertThrowsError(
      try ClockOverlayTexture(
        colorTexture: validColor,
        alphaTexture: makeTexture(
          device: device,
          pixelFormat: .rgba8Unorm,
          width: 16,
          height: 16,
          usage: .shaderRead
        )
      )
    ) { error in
      assertEqual(error as? ClockOverlayTextureError, .alphaTextureMustBeR8)
    }
    assertThrowsError(
      try ClockOverlayTexture(
        colorTexture: validColor,
        alphaTexture: makeTexture(
          device: device,
          pixelFormat: .r8Unorm,
          width: 16,
          height: 16,
          usage: .renderTarget
        )
      )
    ) { error in
      assertEqual(error as? ClockOverlayTextureError, .alphaTextureMustBeSampleable2D)
    }
    assertThrowsError(
      try ClockOverlayTexture(
        colorTexture: validColor,
        alphaTexture: makeTexture(
          device: device,
          pixelFormat: .r8Unorm,
          width: 8,
          height: 16,
          usage: .shaderRead
        )
      )
    ) { error in
      assertEqual(error as? ClockOverlayTextureError, .textureSizeMismatch)
    }
  }

  @Test func metalRendererCreatesRetainedRGB565AndOptionalR8Textures() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = try MetalClockOverlayRenderer(device: device)
    let translucent = try renderer.renderClockOverlay(
      ClockOverlayRenderRequest(
        text: "12:34:56",
        component: ClockComponent(),
        pixelWidth: 320,
        pixelHeight: 96
      ))

    assertEqual(translucent.colorTexture.pixelFormat, .b5g6r5Unorm)
    assertEqual(translucent.alphaTexture?.pixelFormat, .r8Unorm)
    assertEqual(translucent.colorTexture.width, 320)
    assertEqual(translucent.colorTexture.height, 96)

    let opaque = try renderer.renderClockOverlay(
      ClockOverlayRenderRequest(
        text: "12:34",
        component: ClockComponent(background: "#000000"),
        pixelWidth: 256,
        pixelHeight: 80
      ))
    assertNil(opaque.alphaTexture)

    let nearlyOpaque = try renderer.renderClockOverlay(
      ClockOverlayRenderRequest(
        text: "12:34",
        component: ClockComponent(background: "rgba(0, 0, 0, 0.9995)"),
        pixelWidth: 256,
        pixelHeight: 80
      ))
    assertEqual(nearlyOpaque.alphaTexture?.pixelFormat, .r8Unorm)

    let malformed = try renderer.renderClockOverlay(
      ClockOverlayRenderRequest(
        text: "12:34",
        component: ClockComponent(
          foregroundRed: .nan,
          foregroundGreen: -1,
          foregroundBlue: 2,
          backgroundAlpha: .infinity,
          background: "invalid"
        ),
        pixelWidth: 128,
        pixelHeight: 64
      ))
    assertEqual(malformed.colorTexture.pixelFormat, .b5g6r5Unorm)
    assertEqual(malformed.alphaTexture?.pixelFormat, .r8Unorm)
  }

  @Test func metalRendererWritesGlyphCoverageIntoRetainedAlphaTexture() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = try MetalClockOverlayRenderer(device: device)
    let overlay = try renderer.renderClockOverlay(
      ClockOverlayRenderRequest(
        text: "88:88",
        component: ClockComponent(background: "transparent"),
        pixelWidth: 192,
        pixelHeight: 96
      ))
    let alphaTexture = try unwrap(overlay.alphaTexture)

    let alpha = try readR8Texture(alphaTexture, using: device)

    assertEqual(alpha.min(), 0)
    assertGreaterThan(alpha.max() ?? 0, 0)
  }

  @Test func metalRendererReportsUnavailableFontWithoutCrashing() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let missingFontURL = URL(fileURLWithPath: "/nonexistent/ldtx-clock-font.ttf")

    assertThrowsError(
      try MetalClockOverlayRenderer(device: device, fontURL: missingFontURL)
    ) { error in
      guard case MetalClockOverlayRendererError.fontDataUnavailable = error else {
        fail("Expected fontDataUnavailable, got \(error)")
        return
      }
    }
  }

  @Test func programClockRegistryOwnsRegistrationOnlyWhileClockIsActive() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let updates = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let registry = try ClockOverlayRuntimeRegistry(
      device: device,
      updateRegistry: updates,
      currentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)
      )
    )
    let step = CompositeProgramStep(
      id: "clock",
      component: .clock(ClockComponent())
    )
    registry.synchronize(
      composite: CompositeProgramDefinition(steps: [step]),
      outputWidth: 640,
      outputHeight: 360
    )

    assertEqual(updates.registrationCountForTesting, 1)
    waitUntil(timeout: 2) {
      registry.retainedTexture(forStepNamed: step.name) != nil
    }

    registry.synchronize(
      composite: CompositeProgramDefinition(),
      outputWidth: 640,
      outputHeight: 360
    )
    assertEqual(updates.registrationCountForTesting, 0)
  }

  @Test func programClockRegistryDeactivatesZeroSizedClockAndReactivatesWhenVisible() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let updates = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let registry = try ClockOverlayRuntimeRegistry(
      device: device,
      updateRegistry: updates,
      currentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)
      )
    )
    let visibleStep = CompositeProgramStep(
      id: "clock",
      component: .clock(ClockComponent(destinationWidth: 0.5, destinationHeight: 0.2))
    )

    registry.synchronize(
      composite: CompositeProgramDefinition(steps: [visibleStep]),
      outputWidth: 640,
      outputHeight: 360
    )
    assertEqual(updates.registrationCountForTesting, 1)
    waitUntil(timeout: 2) {
      registry.retainedTexture(forStepNamed: visibleStep.name) != nil
    }

    let zeroSizedStep = CompositeProgramStep(
      id: visibleStep.id,
      component: .clock(ClockComponent(destinationWidth: 0, destinationHeight: 0.2))
    )
    registry.synchronize(
      composite: CompositeProgramDefinition(steps: [zeroSizedStep]),
      outputWidth: 640,
      outputHeight: 360
    )
    assertEqual(updates.registrationCountForTesting, 0)
    assertNil(registry.retainedTexture(forStepNamed: visibleStep.name))

    registry.synchronize(
      composite: CompositeProgramDefinition(steps: [visibleStep]),
      outputWidth: 640,
      outputHeight: 360
    )
    assertEqual(updates.registrationCountForTesting, 1)
    waitUntil(timeout: 2) {
      registry.retainedTexture(forStepNamed: visibleStep.name) != nil
    }

    registry.deactivateAll()
    assertEqual(updates.registrationCountForTesting, 0)
  }

  @Test func clockDestinationRectClampsExtremeOutputDimensionsWithoutTrapping() {
    let rect = ClockComponent(
      destinationX: 0,
      destinationY: 0,
      destinationWidth: 1,
      destinationHeight: 1
    ).destinationRect(outputWidth: .max, outputHeight: .max)

    assertEqual(
      rect,
      SIMD4<UInt32>(0, 0, UInt32.max, UInt32.max)
    )
    assertEqual(
      ClockComponent().destinationRect(outputWidth: -1, outputHeight: -1),
      .zero
    )
  }

  @Test func programClockRegistryTracksMultipleClocksIndependently() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let updates = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let registry = try ClockOverlayRuntimeRegistry(
      device: device,
      updateRegistry: updates,
      currentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)
      )
    )
    let first = CompositeProgramStep(
      id: "first-clock",
      component: .clock(ClockComponent(destinationWidth: 0.25))
    )
    let second = CompositeProgramStep(
      id: "second-clock",
      component: .clock(
        ClockComponent(destinationX: 0.5, destinationWidth: 0.4, showsSeconds: false))
    )

    registry.synchronize(
      composite: CompositeProgramDefinition(steps: [first, second]),
      outputWidth: 640,
      outputHeight: 360
    )

    assertEqual(updates.registrationCountForTesting, 2)
    waitUntil(timeout: 2) {
      registry.retainedTexture(forStepNamed: first.name) != nil
        && registry.retainedTexture(forStepNamed: second.name) != nil
    }
    assertEqual(
      registry.retainedTexture(forStepNamed: first.name)?.destinationRect,
      SIMD4<UInt32>(0, 0, 160, 360)
    )
    assertEqual(
      registry.retainedTexture(forStepNamed: second.name)?.destinationRect,
      SIMD4<UInt32>(320, 0, 576, 360)
    )

    registry.synchronize(
      composite: CompositeProgramDefinition(steps: [second]),
      outputWidth: 640,
      outputHeight: 360
    )
    assertEqual(updates.registrationCountForTesting, 1)
    assertNil(registry.retainedTexture(forStepNamed: first.name))

    registry.deactivateAll()
    assertEqual(updates.registrationCountForTesting, 0)
  }

  @Test func clockPlacementClipsWithoutChangingRenderedSize() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let updates = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let registry = try ClockOverlayRuntimeRegistry(
      device: device,
      updateRegistry: updates,
      currentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)
      )
    )
    let stepName = "clock"
    registry.synchronize(
      composite: CompositeProgramDefinition(steps: [
        CompositeProgramStep(
          id: stepName,
          component: .clock(ClockComponent(destinationX: 0.25))
        )
      ]),
      outputWidth: 640,
      outputHeight: 360
    )
    waitUntil(timeout: 2) { registry.retainedTexture(forStepNamed: stepName) != nil }
    let first = try unwrap(registry.retainedTexture(forStepNamed: stepName))
    assertEqual(first.colorTexture.width, 640)
    assertEqual(first.colorTexture.height, 360)
    assertEqual(first.destinationRect, SIMD4<UInt32>(160, 0, 640, 360))
    assertEqual(first.sourceRect, SIMD4<Float>(0, 0, 0.75, 1))

    registry.synchronize(
      composite: CompositeProgramDefinition(steps: [
        CompositeProgramStep(
          id: stepName,
          component: .clock(ClockComponent(destinationX: 0.5))
        )
      ]),
      outputWidth: 640,
      outputHeight: 360
    )
    let moved = try unwrap(registry.retainedTexture(forStepNamed: stepName))
    assertTrue(moved.colorTexture === first.colorTexture)
    assertEqual(moved.destinationRect, SIMD4<UInt32>(320, 0, 640, 360))
    assertEqual(moved.sourceRect, SIMD4<Float>(0, 0, 0.5, 1))
    registry.deactivateAll()
  }

  @Test func rendererInitializationFailureIsNotRetriedAtCanvasFrameRate() throws {
    _ = try unwrap(MTLCreateSystemDefaultDevice())
    let attempts = ClockOverlayInitializationAttemptCounter()
    let renderer = ActiveProgramRenderer(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry(interval: .seconds(60)),
      clockOverlayRegistryFactory: { _, _, _ in
        attempts.increment()
        throw ClockOverlayRendererSpyError.requestedFailure
      }
    )
    var configuration = clockRuntimeConfiguration(
      component: ClockComponent(foregroundRed: .nan)
    )

    renderer.beginSession(1)
    _ = try renderer.render(configuration: configuration, sessionID: 1, frameID: 1)
    _ = try renderer.render(configuration: configuration, sessionID: 1, frameID: 2)
    assertEqual(attempts.value, 1)

    configuration = clockRuntimeConfiguration(
      component: ClockComponent(showsSeconds: false)
    )
    _ = try renderer.render(configuration: configuration, sessionID: 1, frameID: 3)
    _ = try renderer.render(configuration: configuration, sessionID: 1, frameID: 4)
    assertEqual(attempts.value, 2)

    renderer.endSession(1)
    renderer.beginSession(2)
    _ = try renderer.render(configuration: configuration, sessionID: 2, frameID: 5)
    assertEqual(attempts.value, 3)
    renderer.endSession(2)
  }

  @Test func canvasFrameTimestampsNeverDetermineDisplayedClockTime() throws {
    _ = try unwrap(MTLCreateSystemDefaultDevice())
    let updates = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let timeProvider = CountingClockCurrentTimeProvider(
      date: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let renderer = ActiveProgramRenderer(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      lowFrequencyUpdateRegistry: updates,
      clockCurrentTimeProvider: timeProvider
    )
    var configuration = clockRuntimeConfiguration(component: ClockComponent())

    renderer.beginSession(1)
    defer { renderer.endSession(1) }
    _ = try renderer.render(configuration: configuration, sessionID: 1, frameID: 1)
    waitUntil(timeout: 2) { timeProvider.invocationCount == 1 }

    for (index, frameTimestamp) in [0, 1, 60, 3_600, 86_400].enumerated() {
      configuration.timeSeconds = Float(frameTimestamp)
      _ = try renderer.render(
        configuration: configuration,
        sessionID: 1,
        frameID: UInt64(index + 2)
      )
    }

    assertEqual(timeProvider.invocationCount, 1)

    timeProvider.date = Date(timeIntervalSince1970: 1_700_000_001)
    updates.notifySubscribersForTesting()
    waitUntil(timeout: 2) { timeProvider.invocationCount == 2 }
  }

  @Test func clockRemovalUnregistersBeforeFrameResourcePreparationCanFail() throws {
    _ = try unwrap(MTLCreateSystemDefaultDevice())
    let updates = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let renderer = ActiveProgramRenderer(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      lowFrequencyUpdateRegistry: updates,
      clockCurrentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)
      )
    )

    renderer.beginSession(1)
    defer { renderer.endSession(1) }
    _ = try renderer.render(
      configuration: clockRuntimeConfiguration(component: ClockComponent()),
      sessionID: 1,
      frameID: 1
    )
    assertEqual(updates.registrationCountForTesting, 1)

    var invalidConfiguration = clockRuntimeConfiguration(
      composite: CompositeProgramDefinition()
    )
    invalidConfiguration.outputWidth = .max
    invalidConfiguration.outputHeight = .max

    assertThrowsError(
      try renderer.render(
        configuration: invalidConfiguration,
        sessionID: 1,
        frameID: 2
      )
    )
    assertEqual(updates.registrationCountForTesting, 0)
  }

  @Test func previewAndOutputConsumersActivateTheSameClockPath() throws {
    let updates = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let runtime = ProgramRuntime(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      lowFrequencyUpdateRegistry: updates,
      clockCurrentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)
      )
    )
    runtime.updateProgram(
      ProgramRuntimeConfiguration(
        composite: CompositeProgramDefinition(steps: [
          CompositeProgramStep(
            id: "clock",
            component: .clock(
              ClockComponent(
                destinationX: 0.1,
                destinationY: 0.1,
                destinationWidth: 0.5,
                destinationHeight: 0.2,
                backgroundRed: 1,
                backgroundGreen: 1,
                backgroundBlue: 1,
                backgroundAlpha: 0.5,
                background: "rgba(255, 255, 255, 0.5)"
              )))
        ]),
        audioChannels: [],
        canvasWidth: 320,
        canvasHeight: 180,
        outputWidth: 320,
        outputHeight: 180,
        frameRate: 30,
        timeSeconds: 0,
        videoPTSMasterCameraID: nil,
        cameraIDsByInputKey: [:],
        cameraInputColorOverrides: [:],
        backgroundRemovalInputKeys: []
      ))

    runtime.startPreview()
    let previewFrame = try waitForVisibleClockFrame(from: runtime, afterFrameID: 0)
    assertEqual(updates.registrationCountForTesting, 1)
    runtime.stopPreview()
    waitUntil(timeout: 2) { updates.registrationCountForTesting == 0 }

    runtime.beginOutput()
    _ = try waitForVisibleClockFrame(from: runtime, afterFrameID: previewFrame.frameID)
    assertEqual(updates.registrationCountForTesting, 1)
    runtime.endOutput()
    waitUntil(timeout: 2) { updates.registrationCountForTesting == 0 }
  }

  @Test func clockStaysRegisteredUntilPreviewAndOutputAreBothInactive() throws {
    let updates = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let runtime = ProgramRuntime(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      lowFrequencyUpdateRegistry: updates,
      clockCurrentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)
      )
    )
    runtime.updateProgram(
      clockRuntimeConfiguration(
        component: ClockComponent(
          destinationX: 0.1,
          destinationY: 0.1,
          destinationWidth: 0.7,
          destinationHeight: 0.5,
          backgroundRed: 1,
          backgroundGreen: 1,
          backgroundBlue: 1,
          backgroundAlpha: 0.5,
          background: "rgba(255, 255, 255, 0.5)"
        )
      ))

    runtime.startPreview()
    runtime.beginOutput()
    _ = try waitForVisibleClockFrame(from: runtime, afterFrameID: 0)
    assertEqual(updates.registrationCountForTesting, 1)

    runtime.stopPreview()
    assertEqual(updates.registrationCountForTesting, 1)

    runtime.endOutput()
    waitUntil(timeout: 2) { updates.registrationCountForTesting == 0 }
  }

  @Test func appOwnedRegistryTracksMultipleProgramRuntimesIndependently() {
    let updates = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let timeProvider = FixedClockCurrentTimeProvider(
      date: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let firstRuntime = ProgramRuntime(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      lowFrequencyUpdateRegistry: updates,
      clockCurrentTimeProvider: timeProvider
    )
    let secondRuntime = ProgramRuntime(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      lowFrequencyUpdateRegistry: updates,
      clockCurrentTimeProvider: timeProvider
    )
    firstRuntime.updateProgram(clockRuntimeConfiguration(component: ClockComponent()))
    secondRuntime.updateProgram(clockRuntimeConfiguration(component: ClockComponent()))

    firstRuntime.startPreview()
    secondRuntime.startPreview()
    waitUntil(timeout: 2) { updates.registrationCountForTesting == 2 }

    firstRuntime.stopPreview()
    waitUntil(timeout: 2) { updates.registrationCountForTesting == 1 }

    secondRuntime.stopPreview()
    waitUntil(timeout: 2) { updates.registrationCountForTesting == 0 }
  }

  @Test func activeProgramAppliesClockAdditionAppearanceUpdateAndRemoval() throws {
    let updates = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let runtime = ProgramRuntime(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      lowFrequencyUpdateRegistry: updates,
      clockCurrentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)
      )
    )
    runtime.updateProgram(clockRuntimeConfiguration(composite: CompositeProgramDefinition()))
    runtime.startPreview()
    defer { runtime.stopPreview() }

    let redClock = ClockComponent(
      destinationX: 0,
      destinationY: 0,
      destinationWidth: 1,
      destinationHeight: 1,
      backgroundRed: 1,
      backgroundGreen: 0,
      backgroundBlue: 0,
      backgroundAlpha: 1,
      background: "#ff0000"
    )
    runtime.updateProgram(clockRuntimeConfiguration(component: redClock))
    let redFrame = try waitForFrame(from: runtime, afterFrameID: 0) { frame in
      let value = self.luma(in: frame.pixelBuffer, x: 1, y: 1)
      return value > 30 && value < 100
    }
    assertEqual(updates.registrationCountForTesting, 1)

    var greenClock = redClock
    greenClock.backgroundRed = 0
    greenClock.backgroundGreen = 1
    greenClock.background = "#00ff00"
    runtime.updateProgram(clockRuntimeConfiguration(component: greenClock))
    let greenFrame = try waitForFrame(from: runtime, afterFrameID: redFrame.frameID) { frame in
      self.luma(in: frame.pixelBuffer, x: 1, y: 1) > 150
    }
    assertEqual(updates.registrationCountForTesting, 1)

    runtime.updateProgram(clockRuntimeConfiguration(composite: CompositeProgramDefinition()))
    _ = try waitForFrame(from: runtime, afterFrameID: greenFrame.frameID) { frame in
      self.luma(in: frame.pixelBuffer, x: 1, y: 1) == 0
    }
    waitUntil(timeout: 2) { updates.registrationCountForTesting == 0 }
  }

  @Test func standalonePreviewUsesInjectedUpdateRegistryAndUnregistersOnStop() {
    let updates = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let controller = ProgramPreviewController(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      lowFrequencyUpdateRegistry: updates,
      clockCurrentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)
      )
    )
    controller.configure(
      configuration: clockRuntimeConfiguration(
        component: ClockComponent(backgroundAlpha: 0.5)
      ))

    controller.start()
    waitUntil(timeout: 2) { updates.registrationCountForTesting == 1 }

    controller.stop()
    waitUntil(timeout: 2) { updates.registrationCountForTesting == 0 }
  }

  @Test func activeProgramRuntimeDeinitUnregistersClockWithoutExplicitStop() {
    let updates = LowFrequencyUpdateRegistry(interval: .seconds(60))
    weak var releasedRuntime: ProgramRuntime?

    autoreleasepool {
      let runtime = ProgramRuntime(
        captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
        lowFrequencyUpdateRegistry: updates,
        clockCurrentTimeProvider: FixedClockCurrentTimeProvider(
          date: Date(timeIntervalSince1970: 1_700_000_000)
        )
      )
      releasedRuntime = runtime
      runtime.updateProgram(clockRuntimeConfiguration(component: ClockComponent()))
      runtime.startPreview()
      waitUntil(timeout: 2) { updates.registrationCountForTesting == 1 }
    }

    waitUntil(timeout: 2) { releasedRuntime == nil }
    waitUntil(timeout: 2) { updates.registrationCountForTesting == 0 }
  }

  @Test func activeStandalonePreviewDeinitUnregistersClockWithoutExplicitStop() {
    let updates = LowFrequencyUpdateRegistry(interval: .seconds(60))
    weak var releasedController: ProgramPreviewController?

    autoreleasepool {
      let controller = ProgramPreviewController(
        captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
        lowFrequencyUpdateRegistry: updates,
        clockCurrentTimeProvider: FixedClockCurrentTimeProvider(
          date: Date(timeIntervalSince1970: 1_700_000_000)
        )
      )
      releasedController = controller
      controller.configure(
        configuration: clockRuntimeConfiguration(component: ClockComponent())
      )
      controller.start()
      waitUntil(timeout: 2) { updates.registrationCountForTesting == 1 }
    }

    waitUntil(timeout: 2) { releasedController == nil }
    waitUntil(timeout: 2) { updates.registrationCountForTesting == 0 }
  }

  @Test func activeSharedPreviewControllerDeinitBalancesPreviewConsumer() {
    let updates = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let runtime = ProgramRuntime(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      lowFrequencyUpdateRegistry: updates,
      clockCurrentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)
      )
    )
    runtime.updateProgram(clockRuntimeConfiguration(component: ClockComponent()))
    weak var releasedController: ProgramPreviewController?

    autoreleasepool {
      let controller = ProgramPreviewController(programRuntime: runtime)
      releasedController = controller
      controller.start()
      waitUntil(timeout: 2) { updates.registrationCountForTesting == 1 }
    }

    waitUntil(timeout: 2) { releasedController == nil }
    waitUntil(timeout: 2) { updates.registrationCountForTesting == 0 }
  }

  @Test func bundledNotoSansFamilyAndLicenseAreAvailable() throws {
    let upright = NotoSansFontResources.uprightVariableFontURL
    let italic = NotoSansFontResources.italicVariableFontURL
    let license = NotoSansFontResources.openFontLicenseURL

    assertEqual(
      sha256(of: try Data(contentsOf: upright)),
      "205aec8c4579688bc66506ca3c01d930a567634f1ddad3fa5c6fb91e0c3c1cd1"
    )
    assertEqual(
      sha256(of: try Data(contentsOf: italic)),
      "a4f45c53480a0b04570af420fbbd674ebb9d61f7e3bb6bb2716cf0280c3f0201"
    )
    let licenseData = try Data(contentsOf: license)
    assertEqual(
      sha256(of: licenseData),
      "cee9892f9f0cc8fe882c9e9537ee6a89621d86ee7ceaf70b02e2b2b1c25c061a"
    )
    assertTrue(
      String(decoding: licenseData, as: UTF8.self).contains(
        "SIL OPEN FONT LICENSE Version 1.1"
      )
    )
  }

  @Test func formatterUsesInjectedTimeZoneAndBoundedPresentation() {
    let formatter = ClockTextFormatter(timeZoneProvider: {
      TimeZone(secondsFromGMT: 9 * 60 * 60)!
    })
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    assertEqual(
      formatter.string(
        from: date,
        component: ClockComponent(showsSeconds: true, uses24HourTime: true)
      ),
      "07:13:20"
    )
    assertEqual(
      formatter.string(
        from: date,
        component: ClockComponent(showsSeconds: false, uses24HourTime: false)
      ),
      "7:13 AM"
    )
    assertEqual(
      formatter.string(
        from: date,
        component: ClockComponent(
          showsSeconds: false,
          uses24HourTime: true,
          showsDate: true,
          usesSystemTimeZone: false,
          utcOffsetMinutes: 0
        )
      ),
      "2023/11/14\n22:13"
    )
  }

  @Test func activationRendersImmediatelyAndDeactivationUnregisters() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device)
    let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let published = expectation(description: "initial retained overlay published")
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(),
      updateRegistry: registry,
      currentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      formatter: ClockTextFormatter(timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }),
      renderer: renderer,
      overlayDidChange: { _ in published.fulfill() }
    )

    runtime.activate()
    wait(for: [published], timeout: 2)

    assertEqual(renderer.requests.map(\.text), ["22:13:20"])
    assertNotNil(runtime.retainedOverlay())
    assertEqual(registry.registrationCountForTesting, 1)

    runtime.deactivate()
    assertEqual(registry.registrationCountForTesting, 0)
  }

  @Test func failedRefreshKeepsTextureAndLaterNotificationRetries() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let calls = expectation(description: "render attempts")
    calls.expectedFulfillmentCount = 3
    let publications = expectation(description: "successful publications")
    publications.expectedFulfillmentCount = 2
    let renderer = ClockOverlayRendererSpy(device: device, failingCalls: [2]) {
      calls.fulfill()
    }
    let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(),
      updateRegistry: registry,
      currentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      formatter: ClockTextFormatter(timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }),
      renderer: renderer,
      overlayDidChange: { _ in publications.fulfill() }
    )

    runtime.activate()
    waitUntil(timeout: 2) { renderer.requests.count == 1 }
    waitUntil(timeout: 2) { runtime.retainedOverlay() != nil }
    let firstTexture = try unwrap(runtime.retainedOverlay())

    var changed = ClockComponent()
    changed.backgroundAlpha = 0.9
    runtime.update(component: changed)
    waitUntil(timeout: 2) { renderer.requests.count == 2 }
    assertTrue(runtime.retainedOverlay() === firstTexture)

    registry.notifySubscribersForTesting()
    wait(for: [calls, publications], timeout: 2)

    assertEqual(renderer.requests.count, 3)
    assertFalse(runtime.retainedOverlay() === firstTexture)
    runtime.deactivate()
  }

  @Test func failedRefreshIsNotRetriedByEquivalentFrameSynchronization() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device, failingCalls: [2])
    let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let rendererQueue = DispatchQueue(
      label: "ClockOverlayRuntimeIntegrationTestSuite.failed-frame-sync")
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(),
      updateRegistry: registry,
      currentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      formatter: ClockTextFormatter(timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }),
      renderer: renderer,
      rendererQueue: rendererQueue
    )

    runtime.activate()
    rendererQueue.sync {}

    let changed = ClockComponent(backgroundAlpha: 0.9)
    runtime.update(component: changed)
    rendererQueue.sync {}
    assertEqual(renderer.requests.count, 2)

    // Program synchronization calls update on every canvas frame. Identical
    // state must not bypass the low-frequency retry policy.
    for _ in 0..<10 {
      runtime.update(component: changed)
    }
    rendererQueue.sync {}
    assertEqual(renderer.requests.count, 2)

    registry.notifySubscribersForTesting()
    rendererQueue.sync {}
    assertEqual(renderer.requests.count, 3)
    runtime.deactivate()
  }

  @Test func destinationUpdateRetriesFailedRefreshWithoutWaitingForNotification() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device, failingCalls: [2])
    let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let rendererQueue = DispatchQueue(
      label: "ClockOverlayRuntimeIntegrationTestSuite.destination-retry")
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(),
      updateRegistry: registry,
      currentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      formatter: ClockTextFormatter(timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }),
      renderer: renderer,
      rendererQueue: rendererQueue
    )

    runtime.activate()
    rendererQueue.sync {}
    let firstTexture = try unwrap(runtime.retainedOverlay())

    var changed = ClockComponent()
    changed.backgroundAlpha = 0.9
    runtime.update(component: changed)
    rendererQueue.sync {}
    assertEqual(renderer.requests.count, 2)
    assertTrue(runtime.retainedOverlay() === firstTexture)

    changed.destinationX = 0.4
    runtime.update(component: changed)
    rendererQueue.sync {}

    assertEqual(renderer.requests.count, 3)
    assertFalse(runtime.retainedOverlay() === firstTexture)
    runtime.deactivate()
  }

  @Test func destinationUpdateDuringFailedRenderKeepsOneRetryPending() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(
      device: device,
      failingCalls: [1],
      blocksFirstCall: true
    )
    let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let rendererQueue = DispatchQueue(
      label: "ClockOverlayRuntimeIntegrationTestSuite.in-flight-destination-retry")
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(),
      updateRegistry: registry,
      currentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      formatter: ClockTextFormatter(timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }),
      renderer: renderer,
      rendererQueue: rendererQueue
    )

    runtime.activate()
    assertTrue(renderer.waitForFirstCall(timeout: 2))

    runtime.update(component: ClockComponent(destinationX: 0.4))
    renderer.unblockFirstCall()
    rendererQueue.sync {}

    assertEqual(renderer.requests.count, 2)
    assertNotNil(runtime.retainedOverlay())
    runtime.deactivate()
  }

  @Test func destinationOnlyUpdatesReuseRetainedTexture() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device)
    let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let rendererQueue = DispatchQueue(
      label: "ClockOverlayRuntimeIntegrationTestSuite.destination-only")
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(),
      updateRegistry: registry,
      currentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      formatter: ClockTextFormatter(timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }),
      renderer: renderer,
      rendererQueue: rendererQueue
    )

    runtime.activate()
    rendererQueue.sync {}
    let initialTexture = try unwrap(runtime.retainedOverlay())
    assertEqual(renderer.requests.count, 1)

    runtime.update(
      component: ClockComponent(
        destinationX: 0.4,
        destinationY: 0.6,
        destinationWidth: 0.32,
        destinationHeight: 0.12
      ))
    registry.notifySubscribersForTesting()
    rendererQueue.sync {}

    assertEqual(renderer.requests.count, 1)
    assertTrue(runtime.retainedOverlay() === initialTexture)

    runtime.update(component: ClockComponent(backgroundAlpha: 0.5))
    rendererQueue.sync {}
    assertEqual(renderer.requests.count, 2)
    assertFalse(runtime.retainedOverlay() === initialTexture)
    runtime.deactivate()
  }

  @Test func malformedColorsAreNormalizedWithoutFrameRateRefreshes() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device)
    let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let rendererQueue = DispatchQueue(
      label: "ClockOverlayRuntimeIntegrationTestSuite.malformed-colors")
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(
        foregroundRed: .nan,
        foregroundGreen: -1,
        foregroundBlue: 2,
        backgroundAlpha: .infinity
      ),
      updateRegistry: registry,
      currentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      formatter: ClockTextFormatter(timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }),
      renderer: renderer,
      rendererQueue: rendererQueue
    )

    runtime.activate()
    rendererQueue.sync {}
    registry.notifySubscribersForTesting()
    rendererQueue.sync {}

    assertEqual(renderer.requests.count, 1)
    let request = try unwrap(renderer.requests.first)
    assertEqual(request.component.foregroundRed, ClockComponent().foregroundRed)
    assertEqual(request.component.foregroundGreen, 0)
    assertEqual(request.component.foregroundBlue, 1)
    assertEqual(request.component.backgroundAlpha, ClockComponent().backgroundAlpha)
    runtime.deactivate()
  }

  @Test func requestsCoalesceToLatestConfigurationWhileRenderIsInFlight() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device, blocksFirstCall: true)
    let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let rendererQueue = DispatchQueue(label: "ClockOverlayRuntimeIntegrationTestSuite.coalescing")
    let publicationCount = ClockOverlayPublicationCounter()
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(backgroundAlpha: 0.8),
      updateRegistry: registry,
      currentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      formatter: ClockTextFormatter(timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }),
      renderer: renderer,
      rendererQueue: rendererQueue,
      overlayDidChange: { _ in publicationCount.increment() }
    )

    runtime.activate()
    assertTrue(renderer.waitForFirstCall(timeout: 2))

    runtime.update(component: ClockComponent(backgroundAlpha: 0.6))
    runtime.update(component: ClockComponent(backgroundAlpha: 0.4))
    registry.notifySubscribersForTesting()
    renderer.unblockFirstCall()
    rendererQueue.sync {}

    assertEqual(renderer.requests.count, 2)
    assertEqual(renderer.requests.last?.component.backgroundAlpha, 0.4)
    assertEqual(publicationCount.value, 1)
    runtime.deactivate()
  }

  @Test func repeatedNotificationsDoNotDiscardEquivalentInFlightRender() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device, blocksFirstCall: true)
    let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let rendererQueue = DispatchQueue(
      label: "ClockOverlayRuntimeIntegrationTestSuite.notification-coalescing")
    let publicationCount = ClockOverlayPublicationCounter()
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(),
      updateRegistry: registry,
      currentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      formatter: ClockTextFormatter(timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }),
      renderer: renderer,
      rendererQueue: rendererQueue,
      overlayDidChange: { _ in publicationCount.increment() }
    )

    runtime.activate()
    assertTrue(renderer.waitForFirstCall(timeout: 2))

    for _ in 0..<3 {
      registry.notifySubscribersForTesting()
    }
    renderer.unblockFirstCall()
    rendererQueue.sync {}

    assertEqual(renderer.requests.count, 1)
    assertEqual(publicationCount.value, 1)
    assertNotNil(runtime.retainedOverlay())
    runtime.deactivate()
  }

  @Test func deactivationDuringRenderSuppressesPublicationAndUnregisters() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device, blocksFirstCall: true)
    let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let rendererQueue = DispatchQueue(label: "ClockOverlayRuntimeIntegrationTestSuite.deactivation")
    let publicationCount = ClockOverlayPublicationCounter()
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(),
      updateRegistry: registry,
      renderer: renderer,
      rendererQueue: rendererQueue,
      overlayDidChange: { _ in publicationCount.increment() }
    )

    runtime.activate()
    assertTrue(renderer.waitForFirstCall(timeout: 2))
    runtime.deactivate()
    assertEqual(registry.registrationCountForTesting, 0)
    renderer.unblockFirstCall()
    rendererQueue.sync {}

    assertEqual(publicationCount.value, 0)
    assertNil(runtime.retainedOverlay())
  }

  @Test func reactivationDuringRenderPublishesOnlyTheReactivatedGeneration() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device, blocksFirstCall: true)
    let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let rendererQueue = DispatchQueue(label: "ClockOverlayRuntimeIntegrationTestSuite.reactivation")
    let publicationCount = ClockOverlayPublicationCounter()
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(backgroundAlpha: 0.8),
      updateRegistry: registry,
      currentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      formatter: ClockTextFormatter(timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }),
      renderer: renderer,
      rendererQueue: rendererQueue,
      overlayDidChange: { _ in publicationCount.increment() }
    )

    runtime.activate()
    assertTrue(renderer.waitForFirstCall(timeout: 2))
    runtime.deactivate()
    runtime.update(component: ClockComponent(backgroundAlpha: 0.4))
    runtime.activate()
    assertEqual(registry.registrationCountForTesting, 1)

    renderer.unblockFirstCall()
    rendererQueue.sync {}

    assertEqual(renderer.requests.count, 2)
    assertEqual(renderer.requests.last?.component.backgroundAlpha, 0.4)
    assertEqual(publicationCount.value, 1)
    assertNotNil(runtime.retainedOverlay())

    runtime.deactivate()
    assertEqual(registry.registrationCountForTesting, 0)
  }

  private func waitUntil(
    timeout: TimeInterval,
    condition: @escaping () -> Bool
  ) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    assertTrue(condition())
  }

  private func clockRuntimeConfiguration(
    component: ClockComponent
  ) -> ProgramRuntimeConfiguration {
    clockRuntimeConfiguration(
      composite: CompositeProgramDefinition(steps: [
        CompositeProgramStep(id: "clock", component: .clock(component))
      ])
    )
  }

  private func clockRuntimeConfiguration(
    composite: CompositeProgramDefinition
  ) -> ProgramRuntimeConfiguration {
    ProgramRuntimeConfiguration(
      composite: composite,
      audioChannels: [],
      canvasWidth: 64,
      canvasHeight: 64,
      outputWidth: 64,
      outputHeight: 64,
      frameRate: 60,
      timeSeconds: 0,
      videoPTSMasterCameraID: nil,
      cameraIDsByInputKey: [:],
      cameraInputColorOverrides: [:],
      backgroundRemovalInputKeys: []
    )
  }

  private func waitForFrame(
    from runtime: ProgramRuntime,
    afterFrameID: UInt64,
    matching predicate: @escaping (ProgramFrame) -> Bool
  ) throws -> ProgramFrame {
    let published = expectation(description: "Matching Program frame")
    let lock = NSLock()
    var matchedFrame: ProgramFrame?
    let subscription = runtime.subscribeFrames(replayLatestFrame: false) { frame in
      let shouldFulfill = lock.withLock { () -> Bool in
        guard matchedFrame == nil, frame.frameID > afterFrameID, predicate(frame) else {
          return false
        }
        matchedFrame = frame
        return true
      }
      if shouldFulfill { published.fulfill() }
    }
    wait(for: [published], timeout: 3)
    subscription.cancel()
    return try unwrap(lock.withLock { matchedFrame })
  }

  private func waitForVisibleClockFrame(
    from runtime: ProgramRuntime,
    afterFrameID: UInt64
  ) throws -> ProgramFrame {
    let published = expectation(description: "Clock visible in Program frame")
    let lock = NSLock()
    var matchedFrame: ProgramFrame?
    let subscription = runtime.subscribeFrames(replayLatestFrame: false) { frame in
      let shouldFulfill = lock.withLock { () -> Bool in
        guard matchedFrame == nil, frame.frameID > afterFrameID,
          self.luma(in: frame.pixelBuffer, x: 40, y: 24) > 100,
          self.luma(in: frame.pixelBuffer, x: 8, y: 4) == 0
        else { return false }
        matchedFrame = frame
        return true
      }
      if shouldFulfill { published.fulfill() }
    }
    wait(for: [published], timeout: 3)
    subscription.cancel()
    return try unwrap(lock.withLock { matchedFrame })
  }

  private func luma(in pixelBuffer: CVPixelBuffer, x: Int, y: Int) -> UInt8 {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
      return 0
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    return
      baseAddress
      .advanced(by: y * bytesPerRow + x)
      .assumingMemoryBound(to: UInt8.self)
      .pointee
  }

  private func sha256(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func readR8Texture(_ texture: MTLTexture, using device: MTLDevice) throws -> [UInt8] {
    assertEqual(texture.pixelFormat, .r8Unorm)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .r8Unorm,
      width: texture.width,
      height: texture.height,
      mipmapped: false
    )
    descriptor.storageMode = .shared
    let stagingTexture = try unwrap(device.makeTexture(descriptor: descriptor))
    let commandQueue = try unwrap(device.makeCommandQueue())
    let commandBuffer = try unwrap(commandQueue.makeCommandBuffer())
    let encoder = try unwrap(commandBuffer.makeBlitCommandEncoder())
    encoder.copy(
      from: texture,
      sourceSlice: 0,
      sourceLevel: 0,
      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
      sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
      to: stagingTexture,
      destinationSlice: 0,
      destinationLevel: 0,
      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
    )
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    assertEqual(commandBuffer.status, .completed)

    var bytes = [UInt8](repeating: 0, count: texture.width * texture.height)
    stagingTexture.getBytes(
      &bytes,
      bytesPerRow: texture.width,
      from: MTLRegionMake2D(0, 0, texture.width, texture.height),
      mipmapLevel: 0
    )
    return bytes
  }

  private func makeTexture(
    device: MTLDevice,
    pixelFormat: MTLPixelFormat,
    width: Int,
    height: Int,
    usage: MTLTextureUsage
  ) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: pixelFormat,
      width: width,
      height: height,
      mipmapped: false
    )
    descriptor.usage = usage
    return try unwrap(device.makeTexture(descriptor: descriptor))
  }
}

private final class TestExpectation: @unchecked Sendable {
  let description: String
  var expectedFulfillmentCount = 1
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var fulfillmentCount = 0
  init(description: String) { self.description = description }
  var fulfilled: Bool { lock.withLock { fulfillmentCount >= expectedFulfillmentCount } }
  func fulfill() {
    lock.withLock { fulfillmentCount += 1 }
    semaphore.signal()
  }
  func wait(until deadline: DispatchTime) -> Bool {
    for _ in 0..<expectedFulfillmentCount where semaphore.wait(timeout: deadline) != .success {
      return false
    }
    return true
  }
}

private struct TestFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

private func expectation(description: String) -> TestExpectation {
  TestExpectation(description: description)
}
private func wait(for expectations: [TestExpectation], timeout: TimeInterval) {
  let deadline = Date().addingTimeInterval(timeout)
  for expectation in expectations {
    while !expectation.wait(until: .now()) && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.001))
    }
    if !expectation.fulfilled {
      Issue.record(TestFailure("Timed out waiting for \(expectation.description)"))
    }
  }
}
private func assertEqual<Value: Equatable>(_ actual: Value, _ expected: Value) {
  if actual != expected { Issue.record(TestFailure("Expected \(expected), got \(actual)")) }
}
private func assertTrue(_ value: Bool) { if !value { Issue.record(TestFailure("Expected true")) } }
private func assertFalse(_ value: Bool) { if value { Issue.record(TestFailure("Expected false")) } }
private func assertNil<Value>(_ value: Value?) {
  if value != nil { Issue.record(TestFailure("Expected nil")) }
}
private func assertNotNil<Value>(_ value: Value?) {
  if value == nil { Issue.record(TestFailure("Expected non-nil value")) }
}
private func assertGreaterThan<Value: Comparable>(_ actual: Value, _ expected: Value) {
  if actual <= expected { Issue.record(TestFailure("Expected greater value")) }
}
private func fail(_ message: String = "Test failed") { Issue.record(TestFailure(message)) }
private func unwrap<Value>(_ value: Value?) throws -> Value { try #require(value) }
private func assertNoThrow<Value>(_ expression: @autoclosure () throws -> Value) {
  do { _ = try expression() } catch { Issue.record(error) }
}
private func assertThrowsError<Value>(
  _ expression: @autoclosure () throws -> Value, _ handler: (Error) -> Void = { _ in }
) {
  do {
    _ = try expression()
    Issue.record(TestFailure("Expected an error"))
  } catch { handler(error) }
}

private struct FixedClockCurrentTimeProvider: ClockCurrentTimeProviding {
  var date: Date

  func now() -> Date {
    date
  }
}

private final class CountingClockCurrentTimeProvider: ClockCurrentTimeProviding, @unchecked Sendable
{
  private let lock = NSLock()
  private var storedDate: Date
  private var count = 0

  init(date: Date) {
    storedDate = date
  }

  var date: Date {
    get { lock.withLock { storedDate } }
    set { lock.withLock { storedDate = newValue } }
  }

  var invocationCount: Int {
    lock.withLock { count }
  }

  func now() -> Date {
    lock.withLock {
      count += 1
      return storedDate
    }
  }
}

private enum ClockOverlayRendererSpyError: Error {
  case requestedFailure
}

private final class ClockOverlayInitializationAttemptCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.withLock { count }
  }

  func increment() {
    lock.withLock { count += 1 }
  }
}

private final class ClockOverlayPublicationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.withLock { count }
  }

  func increment() {
    lock.withLock { count += 1 }
  }
}

private final class ClockOverlayRendererSpy: ClockOverlayRendering, @unchecked Sendable {
  private let lock = NSLock()
  private let device: MTLDevice
  private let failingCalls: Set<Int>
  private let blocksFirstCall: Bool
  private let onRender: @Sendable () -> Void
  private let firstCallStarted = DispatchSemaphore(value: 0)
  private let firstCallRelease = DispatchSemaphore(value: 0)
  private var storedRequests: [ClockOverlayRenderRequest] = []

  init(
    device: MTLDevice,
    failingCalls: Set<Int> = [],
    blocksFirstCall: Bool = false,
    onRender: @escaping @Sendable () -> Void = {}
  ) {
    self.device = device
    self.failingCalls = failingCalls
    self.blocksFirstCall = blocksFirstCall
    self.onRender = onRender
  }

  var requests: [ClockOverlayRenderRequest] {
    lock.withLock { storedRequests }
  }

  func waitForFirstCall(timeout: TimeInterval) -> Bool {
    firstCallStarted.wait(timeout: .now() + timeout) == .success
  }

  func unblockFirstCall() {
    firstCallRelease.signal()
  }

  func renderClockOverlay(_ request: ClockOverlayRenderRequest) throws -> ClockOverlayTexture {
    let call = lock.withLock { () -> Int in
      storedRequests.append(request)
      return storedRequests.count
    }
    onRender()
    if call == 1, blocksFirstCall {
      firstCallStarted.signal()
      firstCallRelease.wait()
    }
    if failingCalls.contains(call) {
      throw ClockOverlayRendererSpyError.requestedFailure
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .b5g6r5Unorm,
      width: 16,
      height: 16,
      mipmapped: false
    )
    descriptor.usage = [.shaderRead, .shaderWrite]
    return try ClockOverlayTexture(
      colorTexture: unwrap(device.makeTexture(descriptor: descriptor)))
  }
}
