// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreVideo
import CryptoKit
import Foundation
import LDTXProgram
@testable import LDTXProgramRuntime
import LDTXRichText
import Metal
import Testing

extension ClockOverlayRuntimeIntegrationTestSuite {
  @Test func oversizedClockRefreshPreservesPreviousTexture() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let registry = try ClockOverlayRuntimeRegistry(
      device: device, currentTimeProvider: FixedClockCurrentTimeProvider(date: Date()))
    defer { registry.deactivateAll() }
    var component = ClockComponent(fontSize: 48)
    func synchronize() {
      registry.synchronize(
        composite: .init(steps: [.init(id: "clock", component: .clock(component))]),
        outputWidth: 1920, outputHeight: 1080)
    }
    synchronize()
    waitUntil(timeout: 2) { registry.retainedTexture(forStepNamed: "clock") != nil }
    let previous = try #require(registry.retainedTexture(forStepNamed: "clock"))
    component.fontSize = 20_000
    synchronize()
    let retained = try #require(registry.retainedTexture(forStepNamed: "clock"))
    #expect(retained.colorTexture === previous.colorTexture)
    component.destinationX = 0.25
    component.destinationY = 0.125
    component.destinationWidth = 0.5
    component.destinationHeight = 2
    synchronize()
    let moved = try #require(registry.retainedTexture(forStepNamed: "clock"))
    #expect(moved.colorTexture === previous.colorTexture)
    #expect(
      moved.destinationRect
        == SIMD4(
          480, 135, 480 + UInt32(previous.colorTexture.width / 2),
          135 + UInt32(previous.colorTexture.height * 2)))
    component.destinationX = -0.01
    synchronize()
    let clipped = try #require(registry.retainedTexture(forStepNamed: "clock"))
    #expect(clipped.destinationRect.x == 0)
    #expect(clipped.sourceRect.x > 0)
    component.destinationX = 2
    synchronize()
    #expect(registry.retainedTexture(forStepNamed: "clock")?.destinationRect == .zero)
    component.destinationX = 0.25
    synchronize()
    let returned = try #require(registry.retainedTexture(forStepNamed: "clock"))
    #expect(returned.colorTexture === previous.colorTexture)
    #expect(returned.destinationRect == moved.destinationRect)
    registry.synchronize(composite: .init(steps: []), outputWidth: 1920, outputHeight: 1080)
    #expect(registry.retainedTexture(forStepNamed: "clock") == nil)
  }

  @Test func naturalClockExtentIncludesBothOutlines() throws {
    let renderer = try MetalClockOverlayRenderer(device: #require(MTLCreateSystemDefaultDevice()))
    var component = ClockComponent(fontSize: 48)
    let plain = try #require(renderer.naturalClockSize(for: component))
    component.outlines = [
      ClockTextOutline(thickness: 8, color: "black"),
      ClockTextOutline(thickness: 8, color: "white"),
    ]
    let outlined = try #require(renderer.naturalClockSize(for: component))
    #expect(outlined == plain + SIMD2<Float>(repeating: 32))
    for thickness: Float in [64, 65, 20_000] {
      component.outlines = [
        ClockTextOutline(thickness: thickness, color: "black"),
        ClockTextOutline(thickness: thickness, color: "white"),
      ]
      let capped = try #require(renderer.naturalClockSize(for: component))
      #expect(capped == plain + SIMD2<Float>(repeating: 256))
    }
    component.outlines = [ClockTextOutline(thickness: .infinity, color: "black")]
    #expect(renderer.naturalClockSize(for: component) == plain)
  }

  @Test func fontSizedClockUsesNativeRasterBeforeLayerScalingOnEitherCanvas() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let renderer = try MetalClockOverlayRenderer(device: device)
    let component = ClockComponent(destinationWidth: 0.5, destinationHeight: 0.5, fontSize: 48)
    let native = try #require(renderer.naturalClockSize(for: component))
    for (width, height) in [(1920, 1080), (1080, 1920)] {
      let registry = try ClockOverlayRuntimeRegistry(
        device: device,
        currentTimeProvider: FixedClockCurrentTimeProvider(
          date: Date(timeIntervalSince1970: 1_700_000_000)))
      defer { registry.deactivateAll() }
      registry.synchronize(
        composite: .init(steps: [.init(id: "font-sized", component: .clock(component))]),
        outputWidth: width, outputHeight: height)
      waitUntil(timeout: 2) { registry.retainedTexture(forStepNamed: "font-sized") != nil }
      let texture = try #require(registry.retainedTexture(forStepNamed: "font-sized"))
      #expect(texture.colorTexture.width == Int(native.x))
      #expect(texture.colorTexture.height == Int(native.y))
      #expect(texture.destinationRect.z == UInt32((native.x * 0.5).rounded(.down)))
      #expect(texture.destinationRect.w == UInt32((native.y * 0.5).rounded(.down)))
    }
  }

  @Test func fontSizeDeterminesNaturalExtentAndRetainedTexture() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let renderer = try MetalClockOverlayRenderer(device: device)
    let small = ClockComponent(fontSize: 24)
    var large = small
    large.fontSize = 48
    let smallSize = try #require(renderer.naturalClockSize(for: small))
    let largeSize = try #require(renderer.naturalClockSize(for: large))
    #expect(largeSize.x > smallSize.x && largeSize.y > smallSize.y)
    var dated = large
    dated.showsDate = true
    let dateSize = try #require(renderer.naturalClockSize(for: dated))
    #expect(dateSize.y > largeSize.y)
    let rendered = try renderer.renderClockOverlay(
      .init(
        text: "12:34:56", component: large,
        pixelWidth: Int(largeSize.x), pixelHeight: Int(largeSize.y)))
    #expect(rendered.colorTexture.width == Int(largeSize.x))
    #expect(rendered.colorTexture.height == Int(largeSize.y))
    let alpha = try readR8Texture(#require(rendered.alphaTexture), using: device)
    #expect(alpha.contains { $0 > 0 })
    large.fontSize = .infinity
    #expect(renderer.naturalClockSize(for: large) == nil)
  }
}

@Suite(.serialized)
struct ClockOverlayRuntimeIntegrationTestSuite {
  @Test func dynamicTextSizeFailureWaitsForConfigurationChange() async throws {
    let renderer = ClockOverlayRendererSpy(
      device: try unwrap(MTLCreateSystemDefaultDevice()), failingCalls: [1],
      failure: .invalidTextureSize)
    var component = ClockComponent()
    component.resolvedRTFD = try richTextData("text")
    let queue = DispatchQueue(label: "ClockOverlayRuntimeIntegrationTestSuite.invalid-size")
    let runtime = ClockOverlayRuntime(
      component: component, pixelWidth: 16_384, pixelHeight: 16_384,
      renderer: renderer, rendererQueue: queue)
    defer { runtime.deactivate() }
    runtime.activate()
    queue.sync {}
    for _ in 0..<10 { runtime.update(component: component) }
    try await Task.sleep(for: .milliseconds(1200))
    #expect(renderer.requests.count == 1)
    #expect(runtime.retainedOverlay() == nil)
    runtime.update(component: component, pixelWidth: 256, pixelHeight: 96)
    try await waitForClock(timeout: 3) { runtime.retainedOverlay() != nil }
    #expect(renderer.requests.count == 2)
  }

  @Test func dynamicTextRetriesFailuresWithoutUpdatesAndStopsAfterSuccess() async throws {
    let renderer = ClockOverlayRendererSpy(
      device: try unwrap(MTLCreateSystemDefaultDevice()), failingCalls: [1, 3])
    var component = ClockComponent()
    component.resolvedRTFD = try richTextData("first")
    let runtime = ClockOverlayRuntime(component: component, renderer: renderer)
    defer { runtime.deactivate() }
    runtime.activate()
    try await waitForClock(timeout: 3) {
      renderer.requests.count == 2 && runtime.retainedOverlay() != nil
    }
    let firstTexture = try unwrap(runtime.retainedOverlay())
    component.resolvedRTFD = try richTextData("second")
    runtime.update(component: component)
    try await waitForClock(timeout: 3) { renderer.requests.count == 3 }
    #expect(runtime.retainedOverlay() === firstTexture)
    try await waitForClock(timeout: 3) {
      renderer.requests.count == 4 && runtime.retainedOverlay() !== firstTexture
    }
    try await Task.sleep(for: .milliseconds(1200))
    #expect(renderer.requests.count == 4)
  }

  @Test func dynamicTextDeactivationCancelsPendingRetry() async throws {
    let renderer = ClockOverlayRendererSpy(
      device: try unwrap(MTLCreateSystemDefaultDevice()), failingCalls: [1])
    var component = ClockComponent()
    component.resolvedRTFD = try richTextData("text")
    let queue = DispatchQueue(label: "ClockOverlayRuntimeIntegrationTestSuite.retry-cancellation")
    let runtime = ClockOverlayRuntime(
      component: component, renderer: renderer, rendererQueue: queue)
    runtime.activate()
    queue.sync {}
    runtime.deactivate()
    try await Task.sleep(for: .milliseconds(1200))
    #expect(renderer.requests.count == 1)
    #expect(runtime.retainedOverlay() == nil)
  }

  @Test func richTextPreservesColorsAndFontSizesWithoutShrinking() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = try MetalClockOverlayRenderer(device: device)
    let text = NSMutableAttributedString(
      string: "Red ",
      attributes: [.font: NSFont(name: "Helvetica-Bold", size: 48)!, .foregroundColor: NSColor.red])
    text.append(
      NSAttributedString(
        string: "Blue",
        attributes: [
          .font: NSFont(name: "Helvetica-Oblique", size: 24)!, .foregroundColor: NSColor.blue,
        ]))
    var component = ClockComponent()
    component.resolvedRTFD = try LDTXRichTextDocument(text).rtfd
    let overlay = try renderer.renderClockOverlay(
      .init(text: "", component: component, pixelWidth: 256, pixelHeight: 80))
    let alpha = try readR8Texture(unwrap(overlay.alphaTexture), using: device)
    var color = [UInt16](repeating: 0, count: 256 * 80)
    color.withUnsafeMutableBytes {
      overlay.colorTexture.getBytes(
        $0.baseAddress!, bytesPerRow: 512, from: MTLRegionMake2D(0, 0, 256, 80), mipmapLevel: 0)
    }
    let redPixels = color.indices.filter {
      alpha[$0] > 128 && (color[$0] >> 11) > 20 && (color[$0] & 31) < 5
    }
    let bluePixels = color.indices.filter {
      alpha[$0] > 128 && (color[$0] & 31) > 20 && (color[$0] >> 11) < 5
    }
    #expect(!redPixels.isEmpty)
    #expect(!bluePixels.isEmpty)
    let redRows = Set(redPixels.map { $0 / 256 })
    let blueRows = Set(bluePixels.map { $0 / 256 })
    #expect(redRows.count > blueRows.count)
    let bitmap = try unwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 80, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 1024, bitsPerPixel: 32))
    for index in color.indices {
      let p = bitmap.bitmapData! + index * 4
      p[0] = UInt8((color[index] >> 11) * 255 / 31)
      p[1] = UInt8(((color[index] >> 5) & 63) * 255 / 63)
      p[2] = UInt8((color[index] & 31) * 255 / 31)
      p[3] = alpha[index]
    }
    try unwrap(bitmap.representation(using: .png, properties: [:])).write(
      to: URL(fileURLWithPath: "/tmp/ldtx-rtfd-render.png"))
    // Adding text beyond a one-line frame must not reduce the first glyph's size.
    func cropped(_ value: String) throws -> [UInt8] {
      var component = ClockComponent()
      component.resolvedRTFD = try richTextData(value)
      let output = try renderer.renderClockOverlay(
        .init(text: "", component: component, pixelWidth: 40, pixelHeight: 60))
      return try readR8Texture(unwrap(output.alphaTexture), using: device)
    }
    #expect(try cropped("M") == cropped(String(repeating: "M", count: 30)))
  }

  @Test func dynamicTextRejectsExcessiveRasterMemoryBeforeAllocation() throws {
    let renderer = try MetalClockOverlayRenderer(device: unwrap(MTLCreateSystemDefaultDevice()))
    var component = ClockComponent()
    component.resolvedRTFD = try richTextData("Text")
    for (width, height) in [(16_384, 16_384), (4096, 2049)] {
      do {
        _ = try renderer.renderClockOverlay(
          .init(text: "Text", component: component, pixelWidth: width, pixelHeight: height))
        Issue.record("Expected oversized Dynamic Text to be rejected")
      } catch MetalClockOverlayRendererError.invalidTextureSize {}
    }
    // Exercise the inclusive budget boundary without drawing millions of glyph pixels.
    let overlay = try renderer.renderClockOverlay(
      .init(text: "", component: component, pixelWidth: 4096, pixelHeight: 2048))
    #expect(overlay.colorTexture.width == 4096)
    #expect(overlay.colorTexture.height == 2048)
  }

  @Test func dynamicTextTexturePreservesUprightGlyphOrientation() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = try MetalClockOverlayRenderer(device: device)
    var component = ClockComponent()
    component.resolvedRTFD = try richTextData("F")
    let overlay = try renderer.renderClockOverlay(
      .init(
        text: "F", component: component, pixelWidth: 128, pixelHeight: 128))
    let alpha = try readR8Texture(unwrap(overlay.alphaTexture), using: device)
    let rows = (0..<128).map { y in alpha[(y * 128)..<((y + 1) * 128)].filter { $0 > 128 }.count }
    let top = try unwrap(rows.firstIndex(where: { $0 > 0 }))
    let bottom = try unwrap(rows.lastIndex(where: { $0 > 0 }))
    let quarter = max(1, (bottom - top + 1) / 4)
    // F's top bar is wider than its lower stem. An inverted bitmap reverses this.
    assertGreaterThan(
      rows[top..<(top + quarter)].reduce(0, +), rows[(bottom - quarter + 1)...bottom].reduce(0, +))
  }

  @Test func dynamicTextUpdatesWithoutPollingTime() async throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let time = CountingClockCurrentTimeProvider(date: Date())
    let renderer = ClockOverlayRendererSpy(device: device)
    var component = ClockComponent()
    component.resolvedRTFD = try richTextData("first")
    let runtime = ClockOverlayRuntime(
      component: component, currentTimeProvider: time, renderer: renderer)
    defer { runtime.deactivate() }
    runtime.activate()
    try await waitForClock(timeout: 3) { renderer.requests.count == 1 }
    try await Task.sleep(for: .milliseconds(1200))
    assertEqual(renderer.requests.count, 1)
    assertEqual(time.invocationCount, 0)
    component.resolvedRTFD = try richTextData("second")
    runtime.update(component: component)
    try await waitForClock(timeout: 3) { renderer.requests.count == 2 }
    assertEqual(renderer.requests.last?.component.resolvedRTFD, component.resolvedRTFD)
  }

  @Test func textureStoreRejectsRemovedAndReplacedGenerations() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let texture = try ClockOverlayTexture(
      colorTexture: makeTexture(
        device: device, pixelFormat: .b5g6r5Unorm, width: 16, height: 16, usage: .shaderRead))
    let store = ProgramOverlayTextureStore()
    let old = UUID()
    let current = UUID()
    store.place(
      "text", generation: old, destination: .init(0, 0, 16, 16), source: .init(0, 0, 1, 1))
    store.place(
      "text", generation: current, destination: .init(0, 0, 16, 16), source: .init(0, 0, 1, 1))
    store.publish(texture, name: "text", generation: old)
    assertTrue(store.snapshot().isEmpty)
    store.publish(texture, name: "text", generation: current)
    assertNotNil(store.snapshot()["text"])
    store.retain([])
    store.publish(texture, name: "text", generation: current)
    assertTrue(store.snapshot().isEmpty)
  }

  @Test func dynamicTextRendersUnicodeAndClearsEmptyValues() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = try MetalClockOverlayRenderer(device: device)
    var component = ClockComponent()
    component.resolvedRTFD = try richTextData("勝利\nピカチュウ")
    let overlay = try renderer.renderClockOverlay(
      ClockOverlayRenderRequest(
        text: "", component: component, pixelWidth: 320, pixelHeight: 100))
    let alpha = try readR8Texture(unwrap(overlay.alphaTexture), using: device)
    assertEqual(alpha.min(), 0)
    assertEqual(alpha.first, 0)
    assertEqual(alpha.last, 0)
    assertGreaterThan(alpha.max() ?? 0, 0)
    component.resolvedRTFD = try richTextData("")
    let empty = try renderer.renderClockOverlay(
      ClockOverlayRenderRequest(
        text: "", component: component, pixelWidth: 320, pixelHeight: 100))
    let emptyAlpha = try readR8Texture(unwrap(empty.alphaTexture), using: device)
    assertEqual(emptyAlpha.max(), 0)
  }

  @Test func timerRefreshesOnlyWhileActiveAndRestartsAfterDeactivation() async throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let timeProvider = CountingClockCurrentTimeProvider(
      date: Date(timeIntervalSince1970: 1_700_000_000))
    let rendererQueue = DispatchQueue(label: "ClockOverlayRuntimeIntegrationTestSuite.timer")
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(), currentTimeProvider: timeProvider,
      renderer: ClockOverlayRendererSpy(device: device), rendererQueue: rendererQueue)
    defer { runtime.deactivate() }

    runtime.activate()
    runtime.activate()
    try await waitForClock(timeout: 10) { timeProvider.invocationCount >= 2 }
    runtime.deactivate()
    rendererQueue.sync {}
    let stoppedCount = timeProvider.invocationCount
    try await Task.sleep(for: .seconds(1.3))
    assertEqual(timeProvider.invocationCount, stoppedCount)

    runtime.activate()
    try await waitForClock(timeout: 10) { timeProvider.invocationCount >= stoppedCount + 2 }
  }

  @Test func deinitializationCancelsTimerWithoutRetainingRuntime() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let timeProvider = CountingClockCurrentTimeProvider(
      date: Date(timeIntervalSince1970: 1_700_000_000))
    let rendererQueue = DispatchQueue(label: "ClockOverlayRuntimeIntegrationTestSuite.timer-deinit")
    weak var releasedRuntime: ClockOverlayRuntime?
    do {
      let runtime = ClockOverlayRuntime(
        component: ClockComponent(), currentTimeProvider: timeProvider,
        renderer: ClockOverlayRendererSpy(device: device), rendererQueue: rendererQueue)
      releasedRuntime = runtime
      runtime.activate()
      waitUntil(timeout: 2) { timeProvider.invocationCount >= 1 }
      rendererQueue.sync {}
    }
    waitUntil(timeout: 2) { releasedRuntime == nil }
    let stoppedCount = timeProvider.invocationCount
    Thread.sleep(forTimeInterval: 1.3)
    assertEqual(timeProvider.invocationCount, stoppedCount)
  }

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

  @Test func metalRendererCreatesRetainedRGB565AndR8Textures() throws {
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

    let malformed = try renderer.renderClockOverlay(
      ClockOverlayRenderRequest(
        text: "12:34",
        component: ClockComponent(
          foregroundRed: .nan,
          foregroundGreen: -1,
          foregroundBlue: 2,
          foregroundAlpha: .infinity
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
        component: ClockComponent(),
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

  @Test func programClockRegistryRetainsTextureOnlyWhileClockIsPresent() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let registry = try ClockOverlayRuntimeRegistry(
      device: device,
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

    waitUntil(timeout: 2) {
      registry.retainedTexture(forStepNamed: step.name) != nil
    }

    registry.synchronize(
      composite: CompositeProgramDefinition(),
      outputWidth: 640,
      outputHeight: 360
    )
    assertNil(registry.retainedTexture(forStepNamed: step.name))
  }

  @Test func programClockRegistryDeactivatesZeroSizedClockAndReactivatesWhenVisible() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let registry = try ClockOverlayRuntimeRegistry(
      device: device,
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
    assertNil(registry.retainedTexture(forStepNamed: visibleStep.name))

    registry.synchronize(
      composite: CompositeProgramDefinition(steps: [visibleStep]),
      outputWidth: 640,
      outputHeight: 360
    )
    waitUntil(timeout: 2) {
      registry.retainedTexture(forStepNamed: visibleStep.name) != nil
    }

    registry.deactivateAll()
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
    let registry = try ClockOverlayRuntimeRegistry(
      device: device,
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
    assertNil(registry.retainedTexture(forStepNamed: first.name))

    registry.deactivateAll()
  }

  @Test func clockPlacementClipsWithoutChangingRenderedSize() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let registry = try ClockOverlayRuntimeRegistry(
      device: device,
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

  @Test func negativeClockDimensionsMirrorTheRetainedTexture() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let registry = try ClockOverlayRuntimeRegistry(
      device: device,
      currentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)))
    defer { registry.deactivateAll() }
    registry.synchronize(
      composite: CompositeProgramDefinition(steps: [
        CompositeProgramStep(
          id: "clock",
          component: .clock(
            ClockComponent(
              destinationX: 0.5, destinationY: 1,
              destinationWidth: -1, destinationHeight: -1)))
      ]), outputWidth: 640, outputHeight: 360)
    waitUntil(timeout: 2) { registry.retainedTexture(forStepNamed: "clock") != nil }
    let texture = try unwrap(registry.retainedTexture(forStepNamed: "clock"))
    assertEqual(texture.colorTexture.width, 640)
    assertEqual(texture.destinationRect, SIMD4<UInt32>(0, 0, 320, 360))
    assertEqual(texture.sourceRect, SIMD4<Float>(0.5, 1, 0, 0))
  }

  @Test func producerInitializationFailureIsNeverRetriedByFrameRendering() throws {
    _ = try unwrap(MTLCreateSystemDefaultDevice())
    let attempts = ClockOverlayInitializationAttemptCounter()
    let producer = ProgramOverlayProducer(registryFactory: {
      attempts.increment()
      throw ClockOverlayRendererSpyError.requestedFailure
    })
    let renderer = ActiveProgramRenderer(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator())
    var configuration = clockRuntimeConfiguration(component: ClockComponent(foregroundRed: .nan))
    configuration.overlayTextures = producer.textures
    producer.update(configuration: configuration)
    producer.update(configuration: configuration)
    waitUntil(timeout: 2) { attempts.value == 1 }
    renderer.beginSession(1)
    defer { renderer.endSession(1) }
    _ = try renderer.render(configuration: configuration, sessionID: 1, frameID: 1)
    _ = try renderer.render(configuration: configuration, sessionID: 1, frameID: 2)
    assertEqual(attempts.value, 1)
    configuration = clockRuntimeConfiguration(component: ClockComponent(showsSeconds: false))
    producer.update(configuration: configuration)
    waitUntil(timeout: 2) { attempts.value == 2 }
    producer.stop()
    producer.update(configuration: configuration)
    waitUntil(timeout: 2) { attempts.value == 3 }
  }

  @Test func producerRetriesUnchangedConfigurationAfterSetupFailure() async throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let attempts = ClockOverlayInitializationAttemptCounter()
    let producer = ProgramOverlayProducer(registryFactory: {
      attempts.increment()
      if attempts.value == 1 { throw ClockOverlayRendererSpyError.requestedFailure }
      return try ClockOverlayRuntimeRegistry(
        device: device, currentTimeProvider: SystemClockCurrentTimeProvider())
    })
    defer { producer.stop() }
    let configuration = clockRuntimeConfiguration(component: ClockComponent())
    producer.update(configuration: configuration)
    try await waitForClock(timeout: 2) { attempts.value == 1 }
    producer.update(configuration: configuration)
    try await Task.sleep(for: .milliseconds(1100))
    #expect(attempts.value == 1)
    producer.update(configuration: configuration)
    try await waitForClock(timeout: 3) { !producer.textures.snapshot().isEmpty }
    #expect(attempts.value == 2)
  }

  @Test func canvasFrameTimestampsNeverDetermineDisplayedClockTime() async throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let timeProvider = CountingClockCurrentTimeProvider(
      date: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let registry = try ClockOverlayRuntimeRegistry(
      device: device, currentTimeProvider: timeProvider)
    let renderer = ActiveProgramRenderer(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator()
    )
    let producer = ProgramOverlayProducer(registryFactory: { registry })
    var configuration = prepared(
      clockRuntimeConfiguration(component: ClockComponent()), using: producer)

    try await waitForClock(timeout: 10) { producer.textures.snapshot()["clock"] != nil }
    let initial = try unwrap(producer.textures.snapshot()["clock"])
    renderer.beginSession(1)
    defer { renderer.endSession(1) }
    _ = try renderer.render(configuration: configuration, sessionID: 1, frameID: 1)

    for (index, frameTimestamp) in [0, 1, 60, 3_600, 86_400].enumerated() {
      configuration.timeSeconds = Float(frameTimestamp)
      _ = try renderer.render(
        configuration: configuration,
        sessionID: 1,
        frameID: UInt64(index + 2)
      )
      assertTrue(
        producer.textures.snapshot()["clock"]?.colorTexture === initial.colorTexture)
    }

    timeProvider.date = Date(timeIntervalSince1970: 1_700_000_001)
    // Timer ticks may occur during pipeline creation and frame rendering. Verify the
    // retained output, rather than assuming an exact number of wall-clock samples.
    // Only a change to the injected clock time should replace the clock texture.
    try await waitForClock(timeout: 10) {
      guard let refreshed = producer.textures.snapshot()["clock"] else { return false }
      return refreshed.colorTexture !== initial.colorTexture
    }
  }

  @Test func previewAndOutputConsumersActivateTheSameClockPath() throws {
    let runtime = ProgramRuntime(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator()
    )
    let producer = ProgramOverlayProducer()
    runtime.updateProgram(
      prepared(
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
                  foregroundRed: 1,
                  foregroundGreen: 1,
                  foregroundBlue: 1,
                  foregroundAlpha: 0.5,
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
        ), using: producer))

    runtime.startPreview()
    let previewFrame = try waitForVisibleClockFrame(from: runtime, afterFrameID: 0)
    runtime.stopPreview()

    runtime.beginOutput()
    _ = try waitForVisibleClockFrame(from: runtime, afterFrameID: previewFrame.frameID)
    runtime.endOutput()
  }

  @Test func activeProgramAppliesClockAdditionAppearanceUpdateAndRemoval() throws {
    let runtime = ProgramRuntime(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator()
    )
    let producer = ProgramOverlayProducer()
    runtime.updateProgram(
      prepared(clockRuntimeConfiguration(composite: CompositeProgramDefinition()), using: producer))
    runtime.startPreview()
    defer { runtime.stopPreview() }

    let redClock = ClockComponent(
      destinationX: 0,
      destinationY: 0,
      destinationWidth: 1,
      destinationHeight: 1,
      foregroundRed: 1,
      foregroundGreen: 0,
      foregroundBlue: 0,
      foregroundAlpha: 1,
    )
    runtime.updateProgram(prepared(clockRuntimeConfiguration(component: redClock), using: producer))
    let redFrame = try waitForFrame(from: runtime, afterFrameID: 0) { frame in
      let value = self.maximumLuma(in: frame.pixelBuffer)
      return value > 30 && value < 100
    }

    var greenClock = redClock
    greenClock.foregroundRed = 0
    greenClock.foregroundGreen = 1
    runtime.updateProgram(
      prepared(clockRuntimeConfiguration(component: greenClock), using: producer))
    let greenFrame = try waitForFrame(from: runtime, afterFrameID: redFrame.frameID) { frame in
      self.maximumLuma(in: frame.pixelBuffer) > 150
    }

    runtime.updateProgram(
      prepared(clockRuntimeConfiguration(composite: CompositeProgramDefinition()), using: producer))
    _ = try waitForFrame(from: runtime, afterFrameID: greenFrame.frameID) { frame in
      self.maximumLuma(in: frame.pixelBuffer) == 0
    }
  }

  @Test func consumerDeinitDoesNotStopExternalOverlayProduction() {
    weak var releasedRuntime: ProgramRuntime?
    let producer = ProgramOverlayProducer()

    autoreleasepool {
      let runtime = ProgramRuntime(
        captureSessionCoordinator: WorkspaceCaptureSessionCoordinator()
      )
      releasedRuntime = runtime
      runtime.updateProgram(
        prepared(clockRuntimeConfiguration(component: ClockComponent()), using: producer))
      runtime.startPreview()
    }

    waitUntil(timeout: 2) { releasedRuntime == nil }
    waitUntil(timeout: 3) { producer.textures.snapshot()["clock"] != nil }
    assertNotNil(producer.textures.snapshot()["clock"])
  }

  @Test func standalonePreviewDeinitDoesNotStopExternalOverlayProduction() {
    weak var releasedController: ProgramPreviewController?
    let producer = ProgramOverlayProducer()

    autoreleasepool {
      let controller = ProgramPreviewController(
        captureSessionCoordinator: WorkspaceCaptureSessionCoordinator()
      )
      releasedController = controller
      controller.configure(
        configuration: prepared(
          clockRuntimeConfiguration(component: ClockComponent()), using: producer)
      )
      controller.start()
    }

    waitUntil(timeout: 2) { releasedController == nil }
    waitUntil(timeout: 3) { producer.textures.snapshot()["clock"] != nil }
    assertNotNil(producer.textures.snapshot()["clock"])
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

  @Test func activationRendersImmediately() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device)
    let published = expectation(description: "initial retained overlay published")
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(),
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

    runtime.deactivate()
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
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(),
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
    changed.foregroundAlpha = 0.9
    runtime.update(component: changed)
    waitUntil(timeout: 2) { renderer.requests.count == 2 }
    assertTrue(runtime.retainedOverlay() === firstTexture)

    runtime.requestRender()
    wait(for: [calls, publications], timeout: 2)

    assertEqual(renderer.requests.count, 3)
    assertFalse(runtime.retainedOverlay() === firstTexture)
    runtime.deactivate()
  }

  @Test func failedRefreshIsNotRetriedByEquivalentFrameSynchronization() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device, failingCalls: [2])
    let rendererQueue = DispatchQueue(
      label: "ClockOverlayRuntimeIntegrationTestSuite.failed-frame-sync")
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(),
      currentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      formatter: ClockTextFormatter(timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }),
      renderer: renderer,
      rendererQueue: rendererQueue
    )

    runtime.activate()
    rendererQueue.sync {}

    let changed = ClockComponent(foregroundAlpha: 0.9)
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

    runtime.requestRender()
    rendererQueue.sync {}
    assertEqual(renderer.requests.count, 3)
    runtime.deactivate()
  }

  @Test func destinationUpdateRetriesFailedRefreshWithoutWaitingForNotification() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device, failingCalls: [2])
    let rendererQueue = DispatchQueue(
      label: "ClockOverlayRuntimeIntegrationTestSuite.destination-retry")
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(),
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
    changed.foregroundAlpha = 0.9
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
    let rendererQueue = DispatchQueue(
      label: "ClockOverlayRuntimeIntegrationTestSuite.in-flight-destination-retry")
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(),
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
    let rendererQueue = DispatchQueue(
      label: "ClockOverlayRuntimeIntegrationTestSuite.destination-only")
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(),
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
    runtime.requestRender()
    rendererQueue.sync {}

    assertEqual(renderer.requests.count, 1)
    assertTrue(runtime.retainedOverlay() === initialTexture)

    runtime.update(component: ClockComponent(foregroundAlpha: 0.5))
    rendererQueue.sync {}
    assertEqual(renderer.requests.count, 2)
    assertFalse(runtime.retainedOverlay() === initialTexture)
    runtime.deactivate()
  }

  @Test func malformedColorsAreNormalizedWithoutFrameRateRefreshes() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device)
    let rendererQueue = DispatchQueue(
      label: "ClockOverlayRuntimeIntegrationTestSuite.malformed-colors")
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(
        foregroundRed: .nan,
        foregroundGreen: -1,
        foregroundBlue: 2,
        foregroundAlpha: .infinity
      ),
      currentTimeProvider: FixedClockCurrentTimeProvider(
        date: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      formatter: ClockTextFormatter(timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }),
      renderer: renderer,
      rendererQueue: rendererQueue
    )

    runtime.activate()
    rendererQueue.sync {}
    runtime.requestRender()
    rendererQueue.sync {}

    assertEqual(renderer.requests.count, 1)
    let request = try unwrap(renderer.requests.first)
    assertEqual(request.component.foregroundRed, ClockComponent().foregroundRed)
    assertEqual(request.component.foregroundGreen, 0)
    assertEqual(request.component.foregroundBlue, 1)
    assertEqual(request.component.foregroundAlpha, ClockComponent().foregroundAlpha)
    runtime.deactivate()
  }

  @Test func requestsCoalesceToLatestConfigurationWhileRenderIsInFlight() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device, blocksFirstCall: true)
    let rendererQueue = DispatchQueue(label: "ClockOverlayRuntimeIntegrationTestSuite.coalescing")
    let publicationCount = ClockOverlayPublicationCounter()
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(foregroundAlpha: 0.8),
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

    runtime.update(component: ClockComponent(foregroundAlpha: 0.6))
    runtime.update(component: ClockComponent(foregroundAlpha: 0.4))
    runtime.requestRender()
    renderer.unblockFirstCall()
    rendererQueue.sync {}

    assertEqual(renderer.requests.count, 2)
    assertEqual(renderer.requests.last?.component.foregroundAlpha, 0.4)
    assertEqual(publicationCount.value, 1)
    runtime.deactivate()
  }

  @Test func repeatedNotificationsDoNotDiscardEquivalentInFlightRender() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device, blocksFirstCall: true)
    let rendererQueue = DispatchQueue(
      label: "ClockOverlayRuntimeIntegrationTestSuite.notification-coalescing")
    let publicationCount = ClockOverlayPublicationCounter()
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(),
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
      runtime.requestRender()
    }
    renderer.unblockFirstCall()
    rendererQueue.sync {}

    assertEqual(renderer.requests.count, 1)
    assertEqual(publicationCount.value, 1)
    assertNotNil(runtime.retainedOverlay())
    runtime.deactivate()
  }

  @Test func deactivationDuringRenderSuppressesPublication() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device, blocksFirstCall: true)
    let rendererQueue = DispatchQueue(label: "ClockOverlayRuntimeIntegrationTestSuite.deactivation")
    let publicationCount = ClockOverlayPublicationCounter()
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(),
      renderer: renderer,
      rendererQueue: rendererQueue,
      overlayDidChange: { _ in publicationCount.increment() }
    )

    runtime.activate()
    assertTrue(renderer.waitForFirstCall(timeout: 2))
    runtime.deactivate()
    renderer.unblockFirstCall()
    rendererQueue.sync {}

    assertEqual(publicationCount.value, 0)
    assertNil(runtime.retainedOverlay())
  }

  @Test func reactivationDuringRenderPublishesOnlyTheReactivatedGeneration() throws {
    let device = try unwrap(MTLCreateSystemDefaultDevice())
    let renderer = ClockOverlayRendererSpy(device: device, blocksFirstCall: true)
    let rendererQueue = DispatchQueue(label: "ClockOverlayRuntimeIntegrationTestSuite.reactivation")
    let publicationCount = ClockOverlayPublicationCounter()
    let runtime = ClockOverlayRuntime(
      component: ClockComponent(foregroundAlpha: 0.8),
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
    runtime.update(component: ClockComponent(foregroundAlpha: 0.4))
    runtime.activate()

    renderer.unblockFirstCall()
    rendererQueue.sync {}

    assertEqual(renderer.requests.count, 2)
    assertEqual(renderer.requests.last?.component.foregroundAlpha, 0.4)
    assertEqual(publicationCount.value, 1)
    assertNotNil(runtime.retainedOverlay())

    runtime.deactivate()
  }

  private func waitForClock(
    timeout: TimeInterval,
    condition: () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition(), "Clock condition did not become true within \(timeout) seconds")
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

  private func prepared(
    _ configuration: ProgramRuntimeConfiguration, using producer: ProgramOverlayProducer
  ) -> ProgramRuntimeConfiguration {
    producer.update(configuration: configuration)
    var configuration = configuration
    configuration.overlayTextures = producer.textures
    return configuration
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
          self.maximumLuma(in: frame.pixelBuffer) > 100,
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

  private func maximumLuma(in pixelBuffer: CVPixelBuffer) -> UInt8 {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 0 }
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    var maximum: UInt8 = 0
    for y in 0..<CVPixelBufferGetHeight(pixelBuffer) {
      for x in 0..<CVPixelBufferGetWidth(pixelBuffer) {
        maximum = max(maximum, bytes[y * stride + x])
      }
    }
    return maximum
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
  private let failure: MetalClockOverlayRendererError?
  private let blocksFirstCall: Bool
  private let onRender: @Sendable () -> Void
  private let firstCallStarted = DispatchSemaphore(value: 0)
  private let firstCallRelease = DispatchSemaphore(value: 0)
  private var storedRequests: [ClockOverlayRenderRequest] = []

  init(
    device: MTLDevice,
    failingCalls: Set<Int> = [],
    failure: MetalClockOverlayRendererError? = nil,
    blocksFirstCall: Bool = false,
    onRender: @escaping @Sendable () -> Void = {}
  ) {
    self.device = device
    self.failingCalls = failingCalls
    self.failure = failure
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
      if let failure { throw failure }
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

private func richTextData(_ value: String) throws -> Data {
  try LDTXRichTextDocument(
    NSAttributedString(
      string: value,
      attributes: [.font: NSFont(name: "Helvetica", size: 48)!, .foregroundColor: NSColor.white])
  ).rtfd
}
