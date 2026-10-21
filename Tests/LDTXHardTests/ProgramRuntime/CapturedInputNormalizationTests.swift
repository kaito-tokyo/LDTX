// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import LDTXBackgroundSegmentation
import LDTXCapture
import LDTXProgram
import LDTXProgramRendering
@testable import LDTXProgramRuntime
import Metal
import Testing

@Suite struct CapturedInputNormalizationIntegrationTestSuite {
  @Test(arguments: [false, true]) func canonicalNV12UsesOriginalBufferAndRange(video: Bool) throws {
    let fixture = try Fixture()
    let input = try fixture.nv12(video: video, values: [81, 90, 240])
    let frame = fixture.frame(input)
    let output = try fixture.normalizer.normalize(frame)
    #expect(output.pixelBuffer === input)
    #expect(output.sourcePresentationTime == frame.sourcePresentationTime)
    #expect(output.captureSessionID == frame.captureSessionID)
    #expect(output.sequenceNumber == frame.sequenceNumber)
  }

  @Test func smpte240MChangesTheTransferCurveRatherThanOnlyRetagging() throws {
    let fixture = try Fixture()
    for (value, expected) in [(8, 9), (16, 18), (32, 34), (128, 129), (192, 193)] {
      let input = try fixture.bgra(
        [value, value, value], transfer: kCVImageBufferTransferFunction_SMPTE_240M_1995)
      let frame = fixture.frame(input)
      let output = try fixture.normalizer.normalize(frame)
      #expect(abs(try fixture.values(output.pixelBuffer)[0] - expected) <= 1)
      #expect(output.sourcePresentationTime == frame.sourcePresentationTime)
      #expect(output.captureSessionID == frame.captureSessionID)
      #expect(output.sequenceNumber == frame.sequenceNumber)
      #expect(
        CFEqual(
          CVBufferCopyAttachment(input, kCVImageBufferTransferFunctionKey, nil),
          kCVImageBufferTransferFunction_SMPTE_240M_1995))
      #expect(
        CFEqual(
          CVBufferCopyAttachment(output.pixelBuffer, kCVImageBufferTransferFunctionKey, nil),
          kCVImageBufferTransferFunction_ITU_R_709_2))
    }
  }

  @Test func sRGBMidGrayIsConvertedTo709CodeValues() throws {
    let fixture = try Fixture()
    let input = try fixture.bgra([128, 128, 128], transfer: kCVImageBufferTransferFunction_sRGB)
    let output = try fixture.normalizer.normalize(fixture.frame(input))
    let values = try fixture.values(output.pixelBuffer)
    #expect(abs(values[0] - 117) <= 1)
    #expect(values[1] == 128 && values[2] == 128)
  }

  @Test(arguments: [false, true]) func bt601MatrixAndRangeAreConvertedNumerically(video: Bool)
    throws
  {
    let fixture = try Fixture()
    // The 601 encoding of red is not the 709 encoding of red.
    let input = try fixture.nv12(video: video, values: video ? [81, 90, 240] : [76, 85, 255])
    CVBufferSetAttachment(
      input, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
    let output = try fixture.normalizer.normalize(fixture.frame(input))
    let result = try fixture.values(output.pixelBuffer)
    for (actual, expected) in zip(result, [54, 98, 255]) { #expect(abs(actual - expected) <= 2) }
    #expect(
      CFEqual(
        CVBufferCopyAttachment(output.pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil),
        kCVImageBufferYCbCrMatrix_ITU_R_709_2))
  }

  @Test(arguments: [
    kCVImageBufferColorPrimaries_P3_D65 as String,
    kCVImageBufferColorPrimaries_ITU_R_2020 as String,
    kCVImageBufferColorPrimaries_SMPTE_C as String,
    kCVImageBufferColorPrimaries_EBU_3213 as String,
    kCVImageBufferColorPrimaries_DCI_P3 as String,
  ])
  func wideGamutPixelsMatchIndependentColorSyncReference(primaries: String) throws {
    let fixture = try Fixture()
    let transfer =
      primaries == kCVImageBufferColorPrimaries_DCI_P3 as String
      ? kCVImageBufferTransferFunction_SMPTE_ST_428_1
      : primaries == kCVImageBufferColorPrimaries_P3_D65 as String
        ? kCVImageBufferTransferFunction_sRGB : kCVImageBufferTransferFunction_ITU_R_2020
    let input = try fixture.bgra(
      [179, 77, 51], primaries: primaries as CFString, transfer: transfer)
    let tags = CVBufferCopyAttachments(input, .shouldPropagate)!
    let sourceSpace = try #require(
      CVImageBufferCreateColorSpaceFromAttachments(tags)?.takeRetainedValue())
    let sourceColor = try #require(
      CGColor(colorSpace: sourceSpace, components: [179.0 / 255, 77.0 / 255, 51.0 / 255, 1]))
    let reference = try #require(
      sourceColor.converted(
        to: CGColorSpace(name: CGColorSpace.coreMedia709)!, intent: .relativeColorimetric,
        options: nil)?.components)
    let y =
      Double(reference[0]) * 0.2126 + Double(reference[1]) * 0.7152 + Double(reference[2]) * 0.0722
    let expected = [
      y, 0.5 + (Double(reference[2]) - y) / 1.8556, 0.5 + (Double(reference[0]) - y) / 1.5748,
    ].map { Int((min(max($0, 0), 1) * 255).rounded()) }
    let output = try fixture.normalizer.normalize(fixture.frame(input))
    for (actual, reference) in zip(try fixture.values(output.pixelBuffer), expected) {
      #expect(abs(actual - reference) <= 2)
    }
    #expect(
      CFEqual(
        CVBufferCopyAttachment(output.pixelBuffer, kCVImageBufferColorPrimariesKey, nil),
        kCVImageBufferColorPrimaries_ITU_R_709_2))
  }

  @Test(arguments: [false, true]) func hdrUsesExplicitSDRShoulderAndPreservesHighlightDifferences(
    pq: Bool
  ) throws {
    let fixture = try Fixture()
    let expected = pq ? [28, 105, 191, 238, 255] : [43, 94, 181, 241, 255]
    var outputs: [Int] = []
    for (value, reference) in zip([64, 128, 192, 240, 255], expected) {
      let input = try fixture.bgra(
        [value, value, value], primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
        transfer: pq
          ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
          : kCVImageBufferTransferFunction_ITU_R_2100_HLG,
        matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020)
      let output = try fixture.normalizer.normalize(fixture.frame(input))
      let result = try fixture.values(output.pixelBuffer)
      #expect(abs(result[0] - reference) <= 3)
      #expect(abs(result[1] - 128) <= 1 && abs(result[2] - 128) <= 1)
      outputs.append(result[0])
    }
    #expect(zip(outputs, outputs.dropFirst()).allSatisfy { $0 < $1 })
    #expect(outputs[2] < 250 && outputs[3] < 250)
  }

  @Test(arguments: [false, true]) func tenBitHDRNV12IsDecodedBeforeToneMapping(full: Bool) throws {
    let fixture = try Fixture()
    let format =
      full
      ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
      : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    let input = try fixture.buffer(format)
    CVPixelBufferLockBaseAddress(input, [])
    for plane in 0..<2 {
      let address = try #require(CVPixelBufferGetBaseAddressOfPlane(input, plane))
        .assumingMemoryBound(to: UInt16.self)
      let stride = CVPixelBufferGetBytesPerRowOfPlane(input, plane) / 2
      let code =
        plane == 0
        ? (full ? Int((128.0 / 255 * 1023).rounded()) : 64 + Int((128.0 / 255 * 876).rounded()))
        : 512
      for y in 0..<CVPixelBufferGetHeightOfPlane(input, plane) {
        for x in 0..<4 { address[y * stride + x] = UInt16(code << 6) }
      }
    }
    CVPixelBufferUnlockBaseAddress(input, [])
    fixture.attach(
      input, primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
      transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
      matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020)
    let output = try fixture.normalizer.normalize(fixture.frame(input))
    #expect(abs(try fixture.values(output.pixelBuffer)[0] - 105) <= 3)
  }

  @Test func cachedConvertedFramesAreImmutableWhileConsumersRetainThem() throws {
    let fixture = try Fixture()
    let pipeline = VideoInputPreprocessingPipeline(
      device: fixture.device, textureCache: fixture.cache)
    pipeline.synchronize(specifications: [
      "camera": .init(cameraID: "camera", captureSessionID: UUID(), mode: .passthrough)
    ])
    let firstFrame = fixture.frame(try fixture.bgra([255, 0, 0]))
    guard case .ready(let first) = pipeline.process(firstFrame, forInputKey: "camera"),
      case .ready(let repeated) = pipeline.process(firstFrame, forInputKey: "camera")
    else {
      Issue.record("Normalization failed")
      return
    }
    #expect(first.frame.pixelBuffer === repeated.frame.pixelBuffer)
    let before = try fixture.values(first.frame.pixelBuffer)
    for value in [32, 64, 128, 192] {
      let next = fixture.frame(try fixture.bgra([value, value, value]), sequence: UInt64(value))
      _ = pipeline.process(next, forInputKey: "camera")
    }
    #expect(try fixture.values(first.frame.pixelBuffer) == before)
  }

  @Test func unknownInputDoesNotStopOtherCameraOrOverlayFramesAndCanRecover() async throws {
    let good = ManualCameraCaptureService()
    let bad = ManualCameraCaptureService()
    let pool = ManualServicePool([good, bad])
    let workspace = WorkspaceCaptureSessionCoordinator(captureServiceFactory: { pool.next() })
    for ids: Set<String> in [["good"], ["good", "bad"]] {
      await withCheckedContinuation { continuation in
        workspace.synchronizePhysicalInputCaptures(
          videoCameraIDs: ids, audioDeviceIDs: [], availableCameraIDs: ids,
          canvasWidth: 16, canvasHeight: 16, frameRate: 30,
          completionHandler: { _ in continuation.resume() })
      }
    }
    let goodStep = CompositeProgramStep(
      id: "good", component: .inputCameraDevice(InputDeviceComponent()))
    let badStep = CompositeProgramStep(
      id: "bad",
      component: .inputCameraDevice(
        InputDeviceComponent(destinationScaleX: 0.25, destinationScaleY: 0.25)))
    let overlay = CompositeProgramStep(
      id: "overlay",
      component: .fillSolidColor(FillSolidColorComponent(red: 1, green: 0, blue: 0, alpha: 0.25)))
    let composite = CompositeProgramDefinition(steps: [overlay, badStep, goodStep])
    let goodKey = composite.inputCameraDeviceMappingKey(for: goodStep)
    let badKey = composite.inputCameraDeviceMappingKey(for: badStep)
    var configuration = ProgramRuntimeConfiguration(
      composite: composite, audioChannels: [], canvasWidth: 16, canvasHeight: 16, outputWidth: 16,
      outputHeight: 16, frameRate: 30, timeSeconds: 0,
      videoPTSMasterCameraID: "good", cameraIDsByInputKey: [goodKey: "good", badKey: "bad"],
      cameraInputColorOverrides: [:], backgroundRemovalInputKeys: [])
    let renderer = ActiveProgramRenderer(captureSessionCoordinator: workspace)
    renderer.beginSession(1)
    defer { renderer.endSession(1) }
    _ = try #require(try good.emitVideo(frameIndex: 1))
    let fixture = try Fixture()
    let invalidBuffer = try fixture.nv12(video: false, values: [81, 90, 240], iosurface: false)
    CVBufferSetAttachment(
      invalidBuffer, kCVImageBufferTransferFunctionKey, "unknown-transfer" as CFString,
      .shouldPropagate)
    #expect(CVBufferCopyAttachment(invalidBuffer, kCVImageBufferTransferFunctionKey, nil) != nil)
    #expect(bad.emit(try makeSample(invalidBuffer), kind: .video))
    let first = try renderer.render(configuration: configuration, sessionID: 1, frameID: 1)
    _ = try #require(try good.emitVideo(frameIndex: 12))
    let second = try renderer.render(configuration: configuration, sessionID: 1, frameID: 2)
    #expect(first.frameID == 1 && second.frameID == 2)
    #expect(hash(first.pixelBuffer) != hash(second.pixelBuffer))
    #expect(second.presentationTime == CMTime(value: 12, timescale: 30))
    configuration.composite.steps[0].component = .fillSolidColor(
      FillSolidColorComponent(red: 0, green: 1, blue: 0, alpha: 0.25))
    let third = try renderer.render(configuration: configuration, sessionID: 1, frameID: 3)
    #expect(hash(second.pixelBuffer) != hash(third.pixelBuffer))
    // A new known frame recovers the failed input without a pipeline rebuild.
    _ = try #require(try bad.emitVideo(frameIndex: 15))
    let recovered = try renderer.render(configuration: configuration, sessionID: 1, frameID: 4)
    #expect(!recovered.isPreparingRenderResources)
    await withCheckedContinuation { continuation in workspace.stopAndReset { continuation.resume() }
    }
  }

  @Test func bgraRunsThroughRealBackgroundRemovalPreprocessor() async throws {
    let fixture = try Fixture()
    let pipeline = VideoInputPreprocessingPipeline(
      device: fixture.device, textureCache: fixture.cache,
      backgroundRemovalPreprocessorFactory: {
        BackgroundRemovalVideoInputPreprocessor(device: $0, textureCache: $1)
      })
    let frame = fixture.frame(try fixture.bgra([128, 90, 64]))
    pipeline.synchronize(specifications: [
      "camera": .init(
        cameraID: "camera", captureSessionID: frame.captureSessionID, mode: .backgroundRemoval)
    ])
    for _ in 0..<1000 {
      switch pipeline.process(frame, forInputKey: "camera") {
      case .ready(let prepared):
        #expect(CVPixelBufferGetPlaneCount(prepared.frame.pixelBuffer) == 2)
        #expect(prepared.frame.pixelBuffer !== frame.pixelBuffer)
        #expect(prepared.alphaTexture != nil)
        #expect(prepared.frame.sourcePresentationTime == frame.sourcePresentationTime)
        return
      case .preparing: try await Task.sleep(for: .milliseconds(20))
      case .unavailable:
        Issue.record("Real background removal rejected normalized BGRA")
        return
      }
    }
    Issue.record("Real background-removal model did not become ready within 20 seconds")
  }

  @Test func convertedYUVRangeOverrideChangesDecodeWithoutRetaggingCapture() throws {
    let fixture = try Fixture()
    let video = try fixture.nv12(video: true, values: [81, 90, 240])
    let full = try fixture.nv12(video: false, values: [81, 90, 240])
    for buffer in [video, full] {
      CVBufferSetAttachment(
        buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4,
        .shouldPropagate)
    }
    let overridden = try fixture.normalizer.normalize(
      fixture.frame(video), rangeOverride: .fullRange)
    let reference = try fixture.normalizer.normalize(fixture.frame(full))
    for (actual, expected) in zip(
      try fixture.values(overridden.pixelBuffer), try fixture.values(reference.pixelBuffer))
    {
      #expect(abs(actual - expected) <= 1)
    }
    #expect(
      CVPixelBufferGetPixelFormatType(video) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    #expect(
      CFEqual(
        CVBufferCopyAttachment(video, kCVImageBufferYCbCrMatrixKey, nil),
        kCVImageBufferYCbCrMatrix_ITU_R_601_4))
  }

  @Test(arguments: [false, true]) func missingYUVMatrixDefaultUsesPrivateCopyAndPreservesFullRange(
    iosurface: Bool
  ) throws {
    let fixture = try Fixture()
    let tagged = try fixture.nv12(video: false, values: [100, 150, 200])
    let missing = try fixture.nv12(video: false, values: [100, 150, 200], iosurface: iosurface)
    for buffer in [tagged, missing] {
      CVBufferSetAttachment(
        buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB,
        .shouldPropagate)
    }
    CVBufferRemoveAttachment(missing, kCVImageBufferYCbCrMatrixKey)
    let actual = try fixture.normalizer.normalize(fixture.frame(missing))
    let reference = try fixture.normalizer.normalize(fixture.frame(tagged))
    #expect(try fixture.values(actual.pixelBuffer) == fixture.values(reference.pixelBuffer))
    #expect(CVBufferCopyAttachment(missing, kCVImageBufferYCbCrMatrixKey, nil) == nil)
    #expect(
      CVPixelBufferGetPixelFormatType(missing) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
  }

  @Test func explicitGammaIsConvertedAndMalformedGammaIsUnavailable() throws {
    let fixture = try Fixture()
    let input = try fixture.bgra([128, 128, 128], iosurface: false)
    CVBufferRemoveAttachment(input, kCVImageBufferTransferFunctionKey)
    CVBufferSetAttachment(input, kCVImageBufferGammaLevelKey, 2.2 as CFNumber, .shouldPropagate)
    let output = try fixture.normalizer.normalize(fixture.frame(input))
    // Independent gamma 2.2 inverse followed by the BT.709 OETF gives 116.4.
    // ColorSync's profile approximation and 8-bit quantization may differ by two codes.
    let linear = pow(128.0 / 255, 2.2)
    let expected = (1.099 * pow(linear, 0.45) - 0.099) * 255
    #expect(abs(Double(try fixture.values(output.pixelBuffer)[0]) - expected) <= 2)
    CVBufferSetAttachment(input, kCVImageBufferGammaLevelKey, (-1.0) as CFNumber, .shouldPropagate)
    #expect(throws: CapturedInputNormalizer.Failure.self) {
      try fixture.normalizer.normalize(fixture.frame(input))
    }
  }

  @Test func rendererDoesNotApplyRangeOverrideTwiceAfterBGRAConversion() async throws {
    let fixture = try Fixture()
    let camera = ManualCameraCaptureService()
    let workspace = WorkspaceCaptureSessionCoordinator(captureServiceFactory: { camera })
    await withCheckedContinuation { continuation in
      workspace.synchronizePhysicalInputCaptures(
        videoCameraIDs: ["camera"], audioDeviceIDs: [], availableCameraIDs: ["camera"],
        canvasWidth: 4, canvasHeight: 4, frameRate: 30,
        completionHandler: { _ in continuation.resume() })
    }
    let source = try fixture.bgra([255, 0, 0])
    #expect(camera.emit(try makeSample(source), kind: .video))
    let step = CompositeProgramStep(
      id: "camera", component: .inputCameraDevice(InputDeviceComponent()))
    let composite = CompositeProgramDefinition(steps: [step])
    let key = composite.inputCameraDeviceMappingKey(for: step)
    let configuration = ProgramRuntimeConfiguration(
      composite: composite, audioChannels: [], canvasWidth: 4, canvasHeight: 4, outputWidth: 4,
      outputHeight: 4, frameRate: 30, timeSeconds: 0, videoPTSMasterCameraID: "camera",
      cameraIDsByInputKey: [key: "camera"], cameraInputColorOverrides: [key: .videoRange],
      backgroundRemovalInputKeys: [])
    let renderer = ActiveProgramRenderer(captureSessionCoordinator: workspace)
    renderer.beginSession(1)
    let rendered = try renderer.render(configuration: configuration, sessionID: 1, frameID: 1)
    let expected = try fixture.normalizer.normalize(fixture.frame(source))
    #expect(try fixture.values(rendered.pixelBuffer) == fixture.values(expected.pixelBuffer))
    renderer.endSession(1)
    await withCheckedContinuation { continuation in workspace.stopAndReset { continuation.resume() }
    }
  }

  private struct Fixture {
    let device: MTLDevice
    let cache: CVMetalTextureCache
    let normalizer: CapturedInputNormalizer
    init() throws {
      device = try #require(MTLCreateSystemDefaultDevice())
      var cache: CVMetalTextureCache?
      try #require(CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess)
      self.cache = try #require(cache)
      normalizer = CapturedInputNormalizer(device: device)
    }
    func buffer(_ format: OSType, iosurface: Bool = true) throws -> CVPixelBuffer {
      var buffer: CVPixelBuffer?
      try #require(
        CVPixelBufferCreate(
          nil, 4, 4, format,
          (iosurface
            ? [
              kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
            ] : [:])
            as CFDictionary, &buffer) == kCVReturnSuccess)
      return try #require(buffer)
    }
    func frame(_ buffer: CVPixelBuffer, sequence: UInt64 = 31) -> CapturedVideoFrame {
      CapturedVideoFrame(
        pixelBuffer: buffer, sourcePresentationTime: CMTime(value: 31, timescale: 60),
        captureSessionID: UUID(), sequenceNumber: sequence)
    }
    func attach(
      _ buffer: CVPixelBuffer, primaries: CFString = kCVImageBufferColorPrimaries_ITU_R_709_2,
      transfer: CFString = kCVImageBufferTransferFunction_ITU_R_709_2,
      matrix: CFString = kCVImageBufferYCbCrMatrix_ITU_R_709_2
    ) {
      CVBufferSetAttachments(
        buffer,
        [
          kCVImageBufferColorPrimariesKey: primaries, kCVImageBufferTransferFunctionKey: transfer,
          kCVImageBufferYCbCrMatrixKey: matrix,
        ] as CFDictionary, .shouldPropagate)
    }
    func bgra(
      _ rgb: [Int], primaries: CFString = kCVImageBufferColorPrimaries_ITU_R_709_2,
      transfer: CFString = kCVImageBufferTransferFunction_sRGB,
      matrix: CFString = kCVImageBufferYCbCrMatrix_ITU_R_709_2,
      iosurface: Bool = true
    ) throws -> CVPixelBuffer {
      let buffer = try buffer(kCVPixelFormatType_32BGRA, iosurface: iosurface)
      CVPixelBufferLockBaseAddress(buffer, [])
      let ptr = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(
        to: UInt8.self)
      for y in 0..<4 {
        for x in 0..<4 {
          for (channel, value) in [rgb[2], rgb[1], rgb[0], 255].enumerated() {
            ptr[y * CVPixelBufferGetBytesPerRow(buffer) + x * 4 + channel] = UInt8(value)
          }
        }
      }
      CVPixelBufferUnlockBaseAddress(buffer, [])
      attach(buffer, primaries: primaries, transfer: transfer, matrix: matrix)
      return buffer
    }
    func nv12(video: Bool, values: [Int], iosurface: Bool = true) throws -> CVPixelBuffer {
      let buffer = try buffer(
        video
          ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
          : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, iosurface: iosurface)
      CVPixelBufferLockBaseAddress(buffer, [])
      for plane in 0..<2 {
        let ptr = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
          .assumingMemoryBound(to: UInt8.self)
        for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
          for x in 0..<4 {
            ptr[y * CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) + x] = UInt8(
              values[plane == 0 ? 0 : 1 + x % 2])
          }
        }
      }
      CVPixelBufferUnlockBaseAddress(buffer, [])
      attach(buffer)
      return buffer
    }
    func values(_ buffer: CVPixelBuffer) throws -> [Int] {
      CVPixelBufferLockBaseAddress(buffer, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
      let y = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(
        to: UInt8.self)
      let uv = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(
        to: UInt8.self)
      return [Int(y[0]), Int(uv[0]), Int(uv[1])]
    }
  }

  private func makeSample(_ buffer: CVPixelBuffer) throws -> CMSampleBuffer {
    var format: CMVideoFormatDescription?
    try #require(
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format) == noErr)
    var sample: CMSampleBuffer?
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 30),
      presentationTimeStamp: CMTime(value: 1, timescale: 30), decodeTimeStamp: .invalid)
    try #require(
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: nil, imageBuffer: buffer, formatDescription: #require(format),
        sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
    return try #require(sample)
  }

  private func hash(_ buffer: CVPixelBuffer) -> Int {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let ptr = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    var result = 0
    for y in 0..<CVPixelBufferGetHeight(buffer) {
      for x in 0..<CVPixelBufferGetWidth(buffer) {
        result = result &* 31 &+ Int(ptr[y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + x])
      }
    }
    return result
  }
}

private final class ManualServicePool: @unchecked Sendable {
  let lock = NSLock()
  var services: [ManualCameraCaptureService]
  init(_ services: [ManualCameraCaptureService]) { self.services = services }
  func next() -> ManualCameraCaptureService { lock.withLock { services.removeFirst() } }
}
