// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AppKit
@testable import LDTXRecordPlayerApplet
import SwiftUI
import Testing

extension AppUIComponentTestSuite.Shard2 {
  @Suite("SwiftUI recording lifetime", .serialized)
  @MainActor
  struct CloseRecordPlayerDocumentIntegrationTestSuite {
    @Test("LUB-1056: Stopped playback ignores a late asset")
    func stoppedPlaybackIgnoresLateAsset() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let document = try await openRecordingTestDocument(url)
      var resumeLoad: CheckedContinuation<AVAsset, Never>?
      document.assetLoader = { _, _ in
        await withCheckedContinuation { resumeLoad = $0 }
      }
      let model = document.model
      model.start()
      for _ in 0..<1000 where resumeLoad == nil { await Task.yield() }
      let continuation = try #require(resumeLoad)
      model.stop()
      continuation.resume(returning: AVMutableComposition())
      for _ in 0..<100 { await Task.yield() }
      #expect(model.player == nil)
    }

    @Test("LUB-1056: Document release stops playback even when the model is retained")
    func releaseStopsPlayback() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      var document: RecordPlayerDocument? = try await openRecordingTestDocument(url)
      let model = try #require(document).model
      model.player = AVPlayer()
      weak var weakDocument = document
      document = nil
      #expect(weakDocument == nil)
      #expect(model.player == nil)
      model.start()
      await Task.yield()
      #expect(model.player == nil)
    }

    @Test("LUB-1056: UI reconstruction reuses the Document-owned playback model")
    func rebuildingRootPreservesPlayback() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let document = try await openRecordingTestDocument(url)
      var loadCount = 0
      document.assetLoader = { _, _ in
        loadCount += 1
        return AVMutableComposition()
      }
      let model = document.model
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      func host() -> NSViewController {
        NSHostingController(
          rootView: LDTXRecordPlayerView(
            model: model, document: document, requestClose: {}))
      }
      window.contentViewController = host()
      window.orderFront(nil)
      for _ in 0..<100 where model.player == nil {
        try await Task.sleep(for: .milliseconds(10))
      }
      let player = try #require(model.player)
      #expect(window.toolbar != nil)
      window.contentViewController = host()
      for _ in 0..<10 { await Task.yield() }
      #expect(document.model === model)
      #expect(model.player === player)
      #expect(loadCount == 1)
    }

    @Test("LUB-1056: Retained UI does not retain a released Document")
    func retainedUIDoesNotRetainDocument() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      var document: RecordPlayerDocument? = try await openRecordingTestDocument(url)
      let model = try #require(document).model
      model.player = AVPlayer()
      let host = NSHostingController(
        rootView: LDTXRecordPlayerView(
          model: model, document: try #require(document), requestClose: {}))
      weak var weakDocument = document
      document = nil
      #expect(weakDocument == nil)
      #expect(model.player == nil)
      #expect(host.view != nil)
    }
  }
}
