// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Foundation
import LDTXWorkspaceAppletService
import Testing

@Suite
struct ScreenCaptureServiceIntegrationTestSuite {
  @Test func savesIdenticalImagesGloballyAndInsideRecording() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let global = root.appendingPathComponent("Pictures")
    let recording = root.appendingPathComponent("Recording.ldtxrecord/Screenshots")
    var buffer: CVPixelBuffer?
    #expect(
      CVPixelBufferCreate(
        kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
    let pixelBuffer = try #require(buffer)
    let service = ScreenCaptureService()
    let result = try service.captureSet(
      sources: [.init(name: "Landscape", pixelBuffer: pixelBuffer, programCanvas: .landscape)],
      capturedAt: Date(timeIntervalSince1970: 0), outputDirectories: [global, recording])
    #expect(result.outputURLs.count == 2)
    #expect(result.screenshots.allSatisfy { $0.programCanvas == .landscape })
    let first = try #require(result.outputURLs.first)
    let second = try #require(result.outputURLs.last)
    #expect(try Data(contentsOf: first) == Data(contentsOf: second))
    let standalone = try service.captureSet(
      sources: [.init(name: "Landscape", pixelBuffer: pixelBuffer)],
      capturedAt: Date(timeIntervalSince1970: 0), outputDirectories: [global])
    #expect(standalone.outputURLs.count == 1)
    #expect(standalone.screenshots.first?.programCanvas == nil)
    #expect(!result.outputURLs.contains(try #require(standalone.outputURLs.first)))
    #expect(throws: (any Error).self) {
      try service.captureSet(sources: [], capturedAt: Date(), outputDirectories: [global])
    }
  }
}
