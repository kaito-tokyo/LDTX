// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreImage
import LDTXProtos
import LDTXWorkspaceAppletService
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ManualOCRRecognitionIntegrationTestSuite {
  @Test func recognizesRenderedTextThroughManualSubmission() async throws {
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 200, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 900, height: 200).fill()
    ("Manual OCR Example" as NSString).draw(
      at: NSPoint(x: 30, y: 70),
      withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState()
    let image = CIImage(cgImage: try #require(bitmap.cgImage))
    let vision = Ldtx_Workspace_V4_OcrVision.with {
      $0.internalID = 11
      $0.recognitionLanguages = ["en-US"]
    }
    let feature = WorkspaceV4VisionFeature()
    var result: String?
    let context = WorkspaceV4VisionFeatureContext(
      vision: { $0 == 11 ? vision : nil }, frameForVision: { _ in .init(image: image) },
      reportResult: { _, text in result = text },
      reportFailure: { _, error in Issue.record("OCR failed: \(error)") })
    feature.synchronize(visions: [.with { $0.ocrVision = vision }], context: context)
    for _ in 0..<2 {
      result = nil
      feature.runOCR(visionInternalID: 11)
      while !feature.canRunOCR(visionInternalID: 11) { await Task.yield() }
      #expect(result?.contains("Manual OCR Example") == true)
    }
    await feature.stop()
  }
}
