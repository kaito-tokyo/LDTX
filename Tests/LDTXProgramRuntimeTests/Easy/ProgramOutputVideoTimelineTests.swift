// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import LDTXProgramRuntime

@Suite("LDTXProgramRuntimeEasyTests", .tags(.easy))
struct ProgramOutputVideoTimelineTests {
  @Test func heldFrameOwnsACopyIndependentFromRendererBufferReuse() throws {
    let source = try makeNV12PixelBuffer()
    fillFirstLumaByte(of: source, with: 17)
    let heldFrame = ProgramOutputHeldVideoFrame()

    heldFrame.update(from: source)
    fillFirstLumaByte(of: source, with: 99)

    let copy = try #require(heldFrame.pixelBuffer)
    #expect(copy !== source)
    #expect(firstLumaByte(of: copy) == 17)
  }

  @Test func missingSourcePTSAdvancesAtNominalFrameRate() {
    var timeline = ProgramOutputVideoTimeline(frameRate: 30)
    let pipelineID = UUID()

    let first = timeline.presentationTime(
      sourcePresentationTime: nil,
      pipelineID: pipelineID,
      initialFallback: .zero
    )
    let second = timeline.presentationTime(
      sourcePresentationTime: nil,
      pipelineID: pipelineID
    )

    #expect(first == .zero)
    #expect(second == CMTime(value: 1, timescale: 30))
  }

  @Test func missingSourcePTSPreservesSkippedFrameCadence() {
    var timeline = ProgramOutputVideoTimeline(frameRate: 30)
    let pipelineID = UUID()

    _ = timeline.presentationTime(
      sourcePresentationTime: nil,
      pipelineID: pipelineID,
      frameID: 10,
      initialFallback: .zero
    )
    let coalesced = timeline.presentationTime(
      sourcePresentationTime: nil,
      pipelineID: pipelineID,
      frameID: 14
    )

    #expect(coalesced == CMTime(value: 4, timescale: 30))
  }

  @Test func newPipelineDoesNotUsePreviousFrameIDSequence() {
    var timeline = ProgramOutputVideoTimeline(frameRate: 30)

    _ = timeline.presentationTime(
      sourcePresentationTime: nil,
      pipelineID: UUID(),
      frameID: 10,
      initialFallback: .zero
    )
    let switched = timeline.presentationTime(
      sourcePresentationTime: nil,
      pipelineID: UUID(),
      frameID: 10_000
    )

    #expect(switched == CMTime(value: 1, timescale: 30))
  }

  @Test func newPipelineIsRebasedWithoutContinuingCapturePTS() {
    var timeline = ProgramOutputVideoTimeline(frameRate: 30)
    let firstPipelineID = UUID()
    let secondPipelineID = UUID()

    let first = timeline.presentationTime(
      sourcePresentationTime: CMTime(value: 300, timescale: 30),
      pipelineID: firstPipelineID
    )
    let held = timeline.presentationTime(
      sourcePresentationTime: nil,
      pipelineID: firstPipelineID
    )
    let restarted = timeline.presentationTime(
      sourcePresentationTime: CMTime(value: 1, timescale: 30),
      pipelineID: secondPipelineID
    )

    #expect(first == CMTime(value: 300, timescale: 30))
    #expect(held == CMTime(value: 301, timescale: 30))
    #expect(restarted == CMTime(value: 302, timescale: 30))
  }

  @Test func repeatedSourcePTSUsesFrameHoldCadence() {
    var timeline = ProgramOutputVideoTimeline(frameRate: 60)
    let pipelineID = UUID()
    let sourcePTS = CMTime(value: 42, timescale: 60)

    _ = timeline.presentationTime(
      sourcePresentationTime: sourcePTS,
      pipelineID: pipelineID
    )
    let repeated = timeline.presentationTime(
      sourcePresentationTime: sourcePTS,
      pipelineID: pipelineID
    )

    #expect(repeated == CMTime(value: 43, timescale: 60))
  }

  private func makeNV12PixelBuffer() throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        16,
        16,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
        &pixelBuffer)
    #expect(status == kCVReturnSuccess)
    return try #require(pixelBuffer)
  }

  private func fillFirstLumaByte(of pixelBuffer: CVPixelBuffer, with value: UInt8) {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.storeBytes(of: value, as: UInt8.self)
  }

  private func firstLumaByte(of pixelBuffer: CVPixelBuffer) -> UInt8? {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    return CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.load(as: UInt8.self)
  }
}
