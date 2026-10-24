// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProtos
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @MainActor
  @Suite(.serialized)
  struct ManualOCRInspectorIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    @Test("LUB-1045: Run remains enabled during recording and displays results")
    func runRemainsEnabledDuringRecordingAndDisplaysResults() async throws {
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      let vision = Ldtx_Workspace_V4_OcrVision.with { $0.internalID = 11 }
      var runs = 0
      let hosting = NSHostingView(
        rootView: OcrVisionInspector(
          stateService: state, vision: .constant(vision), canRun: { true },
          run: {
            runs += 1
            state.visionResults[11] = "Manual OCR visible result"
          }
        ).frame(width: 480, height: 1100))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 1100),
        styleMask: .titled, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      window.contentView = hosting
      window.makeKeyAndOrderFront(nil)
      func clickRun() throws {
        // Exercise the hosted SwiftUI control directly; Form's virtual buttons
        // are not exposed by in-process NSAccessibility enumeration on macOS 27.
        let point = hosting.convert(
          NSPoint(x: 75, y: hosting.isFlipped ? 68 : hosting.bounds.height - 68), to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
          let event = try #require(
            NSEvent.mouseEvent(
              with: type, location: point, modifierFlags: [], timestamp: 0,
              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
              clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
          window.sendEvent(event)
        }
      }
      for active in [false, true] {
        state.isOutputActive = active
        await settleWorkspaceToolbar(window)
        try clickRun()
        await settleWorkspaceToolbar(window)
        #expect(runs == (active ? 2 : 1))
        #expect(state.visionResults[11] == "Manual OCR visible result")
        if active {
          let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
          hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
          try #require(bitmap.representation(using: .png, properties: [:])).write(
            to: URL(fileURLWithPath: "/tmp/ldtx-273-recording-inspector.png"))
        }
      }
      state.isClosed = true
      await settleWorkspaceToolbar(window)
      try clickRun()
      await settleWorkspaceToolbar(window)
      #expect(runs == 2)
    }
  }
}
