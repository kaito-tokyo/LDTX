// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import CryptoKit
import Foundation
import LDTXProgram
import Metal
import XCTest

@testable import LDTXProgramRuntime

final class ClockOverlayRuntimeTests: XCTestCase {
  func testRetainedClockTextureRejectsInvalidCompositorContracts() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
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

    XCTAssertNoThrow(
      try ClockOverlayTexture(colorTexture: validColor, alphaTexture: validAlpha)
    )
    XCTAssertThrowsError(
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
      XCTAssertEqual(error as? ClockOverlayTextureError, .colorTextureMustBeRGB565)
    }
    XCTAssertThrowsError(
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
      XCTAssertEqual(error as? ClockOverlayTextureError, .colorTextureMustBeSampleable2D)
    }
    XCTAssertThrowsError(
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
      XCTAssertEqual(error as? ClockOverlayTextureError, .alphaTextureMustBeR8)
    }
    XCTAssertThrowsError(
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
      XCTAssertEqual(error as? ClockOverlayTextureError, .alphaTextureMustBeSampleable2D)
    }
    XCTAssertThrowsError(
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
      XCTAssertEqual(error as? ClockOverlayTextureError, .textureSizeMismatch)
    }
  }

  func testMetalRendererCreatesRetainedRGB565AndOptionalR8Textures() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = try MetalClockOverlayRenderer(device: device)
    let translucent = try renderer.renderClockOverlay(
      ClockOverlayRenderRequest(
        text: "12:34:56",
        component: ClockComponent(),
        pixelWidth: 320,
        pixelHeight: 96
      ))

    XCTAssertEqual(translucent.colorTexture.pixelFormat, .b5g6r5Unorm)
    XCTAssertEqual(translucent.alphaTexture?.pixelFormat, .r8Unorm)
    XCTAssertEqual(translucent.colorTexture.width, 320)
    XCTAssertEqual(translucent.colorTexture.height, 96)

    let opaque = try renderer.renderClockOverlay(
      ClockOverlayRenderRequest(
        text: "12:34",
        component: ClockComponent(background: "#000000"),
        pixelWidth: 256,
        pixelHeight: 80
      ))
    XCTAssertNil(opaque.alphaTexture)

    let nearlyOpaque = try renderer.renderClockOverlay(
      ClockOverlayRenderRequest(
        text: "12:34",
        component: ClockComponent(background: "rgba(0, 0, 0, 0.9995)"),
        pixelWidth: 256,
        pixelHeight: 80
      ))
    XCTAssertEqual(nearlyOpaque.alphaTexture?.pixelFormat, .r8Unorm)

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
    XCTAssertEqual(malformed.colorTexture.pixelFormat, .b5g6r5Unorm)
    XCTAssertEqual(malformed.alphaTexture?.pixelFormat, .r8Unorm)
  }

  func testMetalRendererWritesGlyphCoverageIntoRetainedAlphaTexture() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = try MetalClockOverlayRenderer(device: device)
    let overlay = try renderer.renderClockOverlay(
      ClockOverlayRenderRequest(
        text: "88:88",
        component: ClockComponent(background: "transparent"),
        pixelWidth: 192,
        pixelHeight: 96
      ))
    let alphaTexture = try XCTUnwrap(overlay.alphaTexture)

    let alpha = try readR8Texture(alphaTexture, using: device)

    XCTAssertEqual(alpha.min(), 0)
    XCTAssertGreaterThan(alpha.max() ?? 0, 0)
  }

  func testMetalRendererReportsUnavailableFontWithoutCrashing() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let missingFontURL = URL(fileURLWithPath: "/nonexistent/ldtx-clock-font.ttf")

    XCTAssertThrowsError(
      try MetalClockOverlayRenderer(device: device, fontURL: missingFontURL)
    ) { error in
      guard case MetalClockOverlayRendererError.fontDataUnavailable = error else {
        XCTFail("Expected fontDataUnavailable, got \(error)")
        return
      }
    }
  }

  func testProgramClockRegistryOwnsRegistrationOnlyWhileClockIsActive() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
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

    XCTAssertEqual(updates.registrationCountForTesting, 1)
    waitUntil(timeout: 2) {
      registry.retainedTexture(forStepNamed: step.name) != nil
    }

    registry.synchronize(
      composite: CompositeProgramDefinition(),
      outputWidth: 640,
      outputHeight: 360
    )
    XCTAssertEqual(updates.registrationCountForTesting, 0)
  }

  func testProgramClockRegistryDeactivatesZeroSizedClockAndReactivatesWhenVisible() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
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
    XCTAssertEqual(updates.registrationCountForTesting, 1)
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
    XCTAssertEqual(updates.registrationCountForTesting, 0)
    XCTAssertNil(registry.retainedTexture(forStepNamed: visibleStep.name))

    registry.synchronize(
      composite: CompositeProgramDefinition(steps: [visibleStep]),
      outputWidth: 640,
      outputHeight: 360
    )
    XCTAssertEqual(updates.registrationCountForTesting, 1)
    waitUntil(timeout: 2) {
      registry.retainedTexture(forStepNamed: visibleStep.name) != nil
    }

    registry.deactivateAll()
    XCTAssertEqual(updates.registrationCountForTesting, 0)
  }

  func testClockDestinationRectClampsExtremeOutputDimensionsWithoutTrapping() {
    let rect = ClockComponent(
      destinationX: 0,
      destinationY: 0,
      destinationWidth: 1,
      destinationHeight: 1
    ).destinationRect(outputWidth: .max, outputHeight: .max)

    XCTAssertEqual(
      rect,
      SIMD4<UInt32>(0, 0, UInt32.max, UInt32.max)
    )
    XCTAssertEqual(
      ClockComponent().destinationRect(outputWidth: -1, outputHeight: -1),
      .zero
    )
  }

  func testProgramClockRegistryTracksMultipleClocksIndependently() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
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

    XCTAssertEqual(updates.registrationCountForTesting, 2)
    waitUntil(timeout: 2) {
      registry.retainedTexture(forStepNamed: first.name) != nil
        && registry.retainedTexture(forStepNamed: second.name) != nil
    }
    XCTAssertEqual(
      registry.retainedTexture(forStepNamed: first.name)?.destinationRect,
      SIMD4<UInt32>(0, 0, 160, 360)
    )
    XCTAssertEqual(
      registry.retainedTexture(forStepNamed: second.name)?.destinationRect,
      SIMD4<UInt32>(320, 0, 576, 360)
    )

    registry.synchronize(
      composite: CompositeProgramDefinition(steps: [second]),
      outputWidth: 640,
      outputHeight: 360
    )
    XCTAssertEqual(updates.registrationCountForTesting, 1)
    XCTAssertNil(registry.retainedTexture(forStepNamed: first.name))

    registry.deactivateAll()
    XCTAssertEqual(updates.registrationCountForTesting, 0)
  }

  func testClockPlacementClipsWithoutChangingRenderedSize() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
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
    let first = try XCTUnwrap(registry.retainedTexture(forStepNamed: stepName))
    XCTAssertEqual(first.colorTexture.width, 640)
    XCTAssertEqual(first.colorTexture.height, 360)
    XCTAssertEqual(first.destinationRect, SIMD4<UInt32>(160, 0, 640, 360))
    XCTAssertEqual(first.sourceRect, SIMD4<Float>(0, 0, 0.75, 1))

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
    let moved = try XCTUnwrap(registry.retainedTexture(forStepNamed: stepName))
    XCTAssertTrue(moved.colorTexture === first.colorTexture)
    XCTAssertEqual(moved.destinationRect, SIMD4<UInt32>(320, 0, 640, 360))
    XCTAssertEqual(moved.sourceRect, SIMD4<Float>(0, 0, 0.5, 1))
    registry.deactivateAll()
  }

  func testRendererInitializationFailureIsNotRetriedAtCanvasFrameRate() throws {
    _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
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
    XCTAssertEqual(attempts.value, 1)

    configuration = clockRuntimeConfiguration(
      component: ClockComponent(showsSeconds: false)
    )
    _ = try renderer.render(configuration: configuration, sessionID: 1, frameID: 3)
    _ = try renderer.render(configuration: configuration, sessionID: 1, frameID: 4)
    XCTAssertEqual(attempts.value, 2)

    renderer.endSession(1)
    renderer.beginSession(2)
    _ = try renderer.render(configuration: configuration, sessionID: 2, frameID: 5)
    XCTAssertEqual(attempts.value, 3)
    renderer.endSession(2)
  }

  func testCanvasFrameTimestampsNeverDetermineDisplayedClockTime() throws {
    _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
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

    XCTAssertEqual(timeProvider.invocationCount, 1)

    timeProvider.date = Date(timeIntervalSince1970: 1_700_000_001)
    updates.notifySubscribersForTesting()
    waitUntil(timeout: 2) { timeProvider.invocationCount == 2 }
  }

  func testClockRemovalUnregistersBeforeFrameResourcePreparationCanFail() throws {
    _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
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
    XCTAssertEqual(updates.registrationCountForTesting, 1)

    var invalidConfiguration = clockRuntimeConfiguration(
      composite: CompositeProgramDefinition()
    )
    invalidConfiguration.outputWidth = .max
    invalidConfiguration.outputHeight = .max

    XCTAssertThrowsError(
      try renderer.render(
        configuration: invalidConfiguration,
        sessionID: 1,
        frameID: 2
      )
    )
    XCTAssertEqual(updates.registrationCountForTesting, 0)
  }

  func testPreviewAndOutputConsumersActivateTheSameClockPath() throws {
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
    XCTAssertEqual(updates.registrationCountForTesting, 1)
    runtime.stopPreview()
    waitUntil(timeout: 2) { updates.registrationCountForTesting == 0 }

    runtime.beginOutput()
    _ = try waitForVisibleClockFrame(from: runtime, afterFrameID: previewFrame.frameID)
    XCTAssertEqual(updates.registrationCountForTesting, 1)
    runtime.endOutput()
    waitUntil(timeout: 2) { updates.registrationCountForTesting == 0 }
  }

  func testClockStaysRegisteredUntilPreviewAndOutputAreBothInactive() throws {
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
    XCTAssertEqual(updates.registrationCountForTesting, 1)

    runtime.stopPreview()
    XCTAssertEqual(updates.registrationCountForTesting, 1)

    runtime.endOutput()
    waitUntil(timeout: 2) { updates.registrationCountForTesting == 0 }
  }

  func testAppOwnedRegistryTracksMultipleProgramRuntimesIndependently() {
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

  func testActiveProgramAppliesClockAdditionAppearanceUpdateAndRemoval() throws {
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
    XCTAssertEqual(updates.registrationCountForTesting, 1)

    var greenClock = redClock
    greenClock.backgroundRed = 0
    greenClock.backgroundGreen = 1
    greenClock.background = "#00ff00"
    runtime.updateProgram(clockRuntimeConfiguration(component: greenClock))
    let greenFrame = try waitForFrame(from: runtime, afterFrameID: redFrame.frameID) { frame in
      self.luma(in: frame.pixelBuffer, x: 1, y: 1) > 150
    }
    XCTAssertEqual(updates.registrationCountForTesting, 1)

    runtime.updateProgram(clockRuntimeConfiguration(composite: CompositeProgramDefinition()))
    _ = try waitForFrame(from: runtime, afterFrameID: greenFrame.frameID) { frame in
      self.luma(in: frame.pixelBuffer, x: 1, y: 1) == 0
    }
    waitUntil(timeout: 2) { updates.registrationCountForTesting == 0 }
  }

  func testStandalonePreviewUsesInjectedUpdateRegistryAndUnregistersOnStop() {
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

  func testActiveProgramRuntimeDeinitUnregistersClockWithoutExplicitStop() {
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

  func testActiveStandalonePreviewDeinitUnregistersClockWithoutExplicitStop() {
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

  func testActiveSharedPreviewControllerDeinitBalancesPreviewConsumer() {
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

  func testBundledNotoSansFamilyAndLicenseAreAvailable() throws {
    let upright = NotoSansFontResources.uprightVariableFontURL
    let italic = NotoSansFontResources.italicVariableFontURL
    let license = NotoSansFontResources.openFontLicenseURL

    XCTAssertEqual(
      sha256(of: try Data(contentsOf: upright)),
      "205aec8c4579688bc66506ca3c01d930a567634f1ddad3fa5c6fb91e0c3c1cd1"
    )
    XCTAssertEqual(
      sha256(of: try Data(contentsOf: italic)),
      "a4f45c53480a0b04570af420fbbd674ebb9d61f7e3bb6bb2716cf0280c3f0201"
    )
    let licenseData = try Data(contentsOf: license)
    XCTAssertEqual(
      sha256(of: licenseData),
      "cee9892f9f0cc8fe882c9e9537ee6a89621d86ee7ceaf70b02e2b2b1c25c061a"
    )
    XCTAssertTrue(
      String(decoding: licenseData, as: UTF8.self).contains(
        "SIL OPEN FONT LICENSE Version 1.1"
      )
    )
  }

  func testFormatterUsesInjectedTimeZoneAndBoundedPresentation() {
    let formatter = ClockTextFormatter(timeZoneProvider: {
      TimeZone(secondsFromGMT: 9 * 60 * 60)!
    })
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    XCTAssertEqual(
      formatter.string(
        from: date,
        component: ClockComponent(showsSeconds: true, uses24HourTime: true)
      ),
      "07:13:20"
    )
    XCTAssertEqual(
      formatter.string(
        from: date,
        component: ClockComponent(showsSeconds: false, uses24HourTime: false)
      ),
      "7:13 AM"
    )
    XCTAssertEqual(
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

  func testActivationRendersImmediatelyAndDeactivationUnregisters() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
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

    XCTAssertEqual(renderer.requests.map(\.text), ["22:13:20"])
    XCTAssertNotNil(runtime.retainedOverlay())
    XCTAssertEqual(registry.registrationCountForTesting, 1)

    runtime.deactivate()
    XCTAssertEqual(registry.registrationCountForTesting, 0)
  }

  func testFailedRefreshKeepsTextureAndLaterNotificationRetries() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
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
    let firstTexture = try XCTUnwrap(runtime.retainedOverlay())

    var changed = ClockComponent()
    changed.backgroundAlpha = 0.9
    runtime.update(component: changed)
    waitUntil(timeout: 2) { renderer.requests.count == 2 }
    XCTAssertTrue(runtime.retainedOverlay() === firstTexture)

    registry.notifySubscribersForTesting()
    wait(for: [calls, publications], timeout: 2)

    XCTAssertEqual(renderer.requests.count, 3)
    XCTAssertFalse(runtime.retainedOverlay() === firstTexture)
    runtime.deactivate()
  }

  func testFailedRefreshIsNotRetriedByEquivalentFrameSynchronization() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device, failingCalls: [2])
    let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let rendererQueue = DispatchQueue(label: "ClockOverlayRuntimeTests.failed-frame-sync")
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
    XCTAssertEqual(renderer.requests.count, 2)

    // Program synchronization calls update on every canvas frame. Identical
    // state must not bypass the low-frequency retry policy.
    for _ in 0..<10 {
      runtime.update(component: changed)
    }
    rendererQueue.sync {}
    XCTAssertEqual(renderer.requests.count, 2)

    registry.notifySubscribersForTesting()
    rendererQueue.sync {}
    XCTAssertEqual(renderer.requests.count, 3)
    runtime.deactivate()
  }

  func testDestinationUpdateRetriesFailedRefreshWithoutWaitingForNotification() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device, failingCalls: [2])
    let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let rendererQueue = DispatchQueue(label: "ClockOverlayRuntimeTests.destination-retry")
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
    let firstTexture = try XCTUnwrap(runtime.retainedOverlay())

    var changed = ClockComponent()
    changed.backgroundAlpha = 0.9
    runtime.update(component: changed)
    rendererQueue.sync {}
    XCTAssertEqual(renderer.requests.count, 2)
    XCTAssertTrue(runtime.retainedOverlay() === firstTexture)

    changed.destinationX = 0.4
    runtime.update(component: changed)
    rendererQueue.sync {}

    XCTAssertEqual(renderer.requests.count, 3)
    XCTAssertFalse(runtime.retainedOverlay() === firstTexture)
    runtime.deactivate()
  }

  func testDestinationUpdateDuringFailedRenderKeepsOneRetryPending() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(
      device: device,
      failingCalls: [1],
      blocksFirstCall: true
    )
    let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let rendererQueue = DispatchQueue(label: "ClockOverlayRuntimeTests.in-flight-destination-retry")
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
    XCTAssertTrue(renderer.waitForFirstCall(timeout: 2))

    runtime.update(component: ClockComponent(destinationX: 0.4))
    renderer.unblockFirstCall()
    rendererQueue.sync {}

    XCTAssertEqual(renderer.requests.count, 2)
    XCTAssertNotNil(runtime.retainedOverlay())
    runtime.deactivate()
  }

  func testDestinationOnlyUpdatesReuseRetainedTexture() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device)
    let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let rendererQueue = DispatchQueue(label: "ClockOverlayRuntimeTests.destination-only")
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
    let initialTexture = try XCTUnwrap(runtime.retainedOverlay())
    XCTAssertEqual(renderer.requests.count, 1)

    runtime.update(
      component: ClockComponent(
        destinationX: 0.4,
        destinationY: 0.6,
        destinationWidth: 0.32,
        destinationHeight: 0.12
      ))
    registry.notifySubscribersForTesting()
    rendererQueue.sync {}

    XCTAssertEqual(renderer.requests.count, 1)
    XCTAssertTrue(runtime.retainedOverlay() === initialTexture)

    runtime.update(component: ClockComponent(backgroundAlpha: 0.5))
    rendererQueue.sync {}
    XCTAssertEqual(renderer.requests.count, 2)
    XCTAssertFalse(runtime.retainedOverlay() === initialTexture)
    runtime.deactivate()
  }

  func testMalformedColorsAreNormalizedWithoutFrameRateRefreshes() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device)
    let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let rendererQueue = DispatchQueue(label: "ClockOverlayRuntimeTests.malformed-colors")
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

    XCTAssertEqual(renderer.requests.count, 1)
    let request = try XCTUnwrap(renderer.requests.first)
    XCTAssertEqual(request.component.foregroundRed, ClockComponent().foregroundRed)
    XCTAssertEqual(request.component.foregroundGreen, 0)
    XCTAssertEqual(request.component.foregroundBlue, 1)
    XCTAssertEqual(request.component.backgroundAlpha, ClockComponent().backgroundAlpha)
    runtime.deactivate()
  }

  func testRequestsCoalesceToLatestConfigurationWhileRenderIsInFlight() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device, blocksFirstCall: true)
    let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let rendererQueue = DispatchQueue(label: "ClockOverlayRuntimeTests.coalescing")
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
    XCTAssertTrue(renderer.waitForFirstCall(timeout: 2))

    runtime.update(component: ClockComponent(backgroundAlpha: 0.6))
    runtime.update(component: ClockComponent(backgroundAlpha: 0.4))
    registry.notifySubscribersForTesting()
    renderer.unblockFirstCall()
    rendererQueue.sync {}

    XCTAssertEqual(renderer.requests.count, 2)
    XCTAssertEqual(renderer.requests.last?.component.backgroundAlpha, 0.4)
    XCTAssertEqual(publicationCount.value, 1)
    runtime.deactivate()
  }

  func testRepeatedNotificationsDoNotDiscardEquivalentInFlightRender() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device, blocksFirstCall: true)
    let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let rendererQueue = DispatchQueue(label: "ClockOverlayRuntimeTests.notification-coalescing")
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
    XCTAssertTrue(renderer.waitForFirstCall(timeout: 2))

    for _ in 0..<3 {
      registry.notifySubscribersForTesting()
    }
    renderer.unblockFirstCall()
    rendererQueue.sync {}

    XCTAssertEqual(renderer.requests.count, 1)
    XCTAssertEqual(publicationCount.value, 1)
    XCTAssertNotNil(runtime.retainedOverlay())
    runtime.deactivate()
  }

  func testDeactivationDuringRenderSuppressesPublicationAndUnregisters() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device, blocksFirstCall: true)
    let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let rendererQueue = DispatchQueue(label: "ClockOverlayRuntimeTests.deactivation")
    let publicationCount = ClockOverlayPublicationCounter()
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(),
      updateRegistry: registry,
      renderer: renderer,
      rendererQueue: rendererQueue,
      overlayDidChange: { _ in publicationCount.increment() }
    )

    runtime.activate()
    XCTAssertTrue(renderer.waitForFirstCall(timeout: 2))
    runtime.deactivate()
    XCTAssertEqual(registry.registrationCountForTesting, 0)
    renderer.unblockFirstCall()
    rendererQueue.sync {}

    XCTAssertEqual(publicationCount.value, 0)
    XCTAssertNil(runtime.retainedOverlay())
  }

  func testReactivationDuringRenderPublishesOnlyTheReactivatedGeneration() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device, blocksFirstCall: true)
    let registry = LowFrequencyUpdateRegistry(interval: .seconds(60))
    let rendererQueue = DispatchQueue(label: "ClockOverlayRuntimeTests.reactivation")
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
    XCTAssertTrue(renderer.waitForFirstCall(timeout: 2))
    runtime.deactivate()
    runtime.update(component: ClockComponent(backgroundAlpha: 0.4))
    runtime.activate()
    XCTAssertEqual(registry.registrationCountForTesting, 1)

    renderer.unblockFirstCall()
    rendererQueue.sync {}

    XCTAssertEqual(renderer.requests.count, 2)
    XCTAssertEqual(renderer.requests.last?.component.backgroundAlpha, 0.4)
    XCTAssertEqual(publicationCount.value, 1)
    XCTAssertNotNil(runtime.retainedOverlay())

    runtime.deactivate()
    XCTAssertEqual(registry.registrationCountForTesting, 0)
  }

  private func waitUntil(
    timeout: TimeInterval,
    condition: @escaping () -> Bool
  ) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(condition())
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
    let handlerID = runtime.addFrameHandler(replayLatestFrame: false) { frame in
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
    runtime.removeFrameHandler(id: handlerID)
    return try XCTUnwrap(lock.withLock { matchedFrame })
  }

  private func waitForVisibleClockFrame(
    from runtime: ProgramRuntime,
    afterFrameID: UInt64
  ) throws -> ProgramFrame {
    let published = expectation(description: "Clock visible in Program frame")
    let lock = NSLock()
    var matchedFrame: ProgramFrame?
    let handlerID = runtime.addFrameHandler(replayLatestFrame: false) { frame in
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
    runtime.removeFrameHandler(id: handlerID)
    return try XCTUnwrap(lock.withLock { matchedFrame })
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
    XCTAssertEqual(texture.pixelFormat, .r8Unorm)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .r8Unorm,
      width: texture.width,
      height: texture.height,
      mipmapped: false
    )
    descriptor.storageMode = .shared
    let stagingTexture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    let commandQueue = try XCTUnwrap(device.makeCommandQueue())
    let commandBuffer = try XCTUnwrap(commandQueue.makeCommandBuffer())
    let encoder = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
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
    XCTAssertEqual(commandBuffer.status, .completed)

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
    return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
  }
}

private struct FixedClockCurrentTimeProvider: ClockCurrentTimeProviding {
  var date: Date

  func now() -> Date {
    date
  }
}

private final class CountingClockCurrentTimeProvider: ClockCurrentTimeProviding, @unchecked Sendable {
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
      colorTexture: XCTUnwrap(device.makeTexture(descriptor: descriptor)))
  }
}
