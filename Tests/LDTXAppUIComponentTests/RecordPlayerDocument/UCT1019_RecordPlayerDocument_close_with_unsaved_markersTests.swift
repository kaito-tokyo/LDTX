// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AppKit
import LDTXAppletSupport
@testable import LDTXRecordPlayerApplet
import LDTXRecording
import LDTXWorkspaceAppletController
import Observation
import SwiftUI
import Testing
import os

extension AppUIComponentTestSuite {
  @Suite("UCT-1019: close-with-unsaved-markers", .serialized)
  @MainActor
  struct UCT1019RecordPlayerDocumentIntegrationTestSuite {
    private static var controller: NSDocumentController {
      UIComponentTestEnvironment.documentController
    }
    init() { _ = Self.controller }

    @Test("UCT-1019.1: Closing a clean recording stops playback")
    func closingCleanWindowClosesDocumentAndStopsPlayback() throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let document = try openRecordingTestDocument(url)
      defer { document.close() }
      Self.controller.addDocument(document)
      document.makeWindowControllers()
      let model = try #require(document.model)
      model.player = AVPlayer()
      let window = try #require(document.windowControllers.first?.window)
      window.orderFront(nil)
      window.performClose(nil)
      #expect(model.player == nil)
      #expect(!Self.controller.documents.contains { $0 === document })
    }

    @Test("UCT-1019.2: Cancel preserves playback and Discard stops it")
    func closeCancelKeepsPlaybackAndDiscardStopsIt() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let document = try openRecordingTestDocument(url)
      defer { document.close() }
      Self.controller.addDocument(document)
      document.makeWindowControllers()
      let model = try #require(document.model)
      let player = AVPlayer()
      model.player = player
      try document.createMarker(note: "Unsaved", at: .zero)
      let window = try #require(document.windowControllers.first?.window)
      window.orderFront(nil)
      let probe = CloseProbe()
      document.canClose(
        withDelegate: probe,
        shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)),
        contextInfo: nil)
      try await clickRecordingSheetButton("Cancel", in: window)
      for _ in 0..<100 where probe.result == nil { try await Task.sleep(for: .milliseconds(10)) }
      #expect(probe.result == false)
      #expect(model.player === player)
      #expect(document.isDocumentEdited)
      #expect(Self.controller.documents.contains { $0 === document })
      probe.result = nil
      document.canClose(
        withDelegate: probe,
        shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)),
        contextInfo: nil)
      try await clickRecordingSheetButton("Don’t Save", in: window)
      for _ in 0..<100 where probe.result == nil { try await Task.sleep(for: .milliseconds(10)) }
      #expect(probe.result == true)
      document.close()
      #expect(model.player == nil)
      #expect(!Self.controller.documents.contains { $0 === document })
      #expect(try RecordingMarkerStore(recordingDirectoryURL: url).markers().isEmpty)
    }

    @Test("UCT-1019.3: Save on close persists markers before allowing closure")
    func closeSaveUsesStandardSaveBeforeAllowingClosure() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let document = try openRecordingTestDocument(url)
      defer { document.close() }
      Self.controller.addDocument(document)
      document.makeWindowControllers()
      let model = try #require(document.model)
      let player = AVPlayer()
      model.player = player
      try document.createMarker(note: "Save on close", at: .zero)
      let window = try #require(document.windowControllers.first?.window)
      window.orderFront(nil)
      let probe = CloseProbe()
      document.canClose(
        withDelegate: probe,
        shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)),
        contextInfo: nil)
      try await clickRecordingSheetButton("Save", in: window)
      for _ in 0..<200 where probe.result == nil { try await Task.sleep(for: .milliseconds(10)) }
      #expect(probe.result == true)
      #expect(!document.isDocumentEdited)
      #expect(
        try RecordingMarkerStore(recordingDirectoryURL: url).markers().map(\.note) == [
          "Save on close"
        ])
      #expect(model.player === player)
      document.close()
      #expect(model.player == nil)
    }

    @Test("UCT-1019.4: Closing cancels pending asset loading")
    func closeCancelsAssetLoadingBeforeItCanRestartPlayback() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      let document = try openRecordingTestDocument(url)
      var continuation: CheckedContinuation<AVAsset, Error>?
      document.assetLoader = { _, _ in
        try await withCheckedThrowingContinuation { continuation = $0 }
      }
      document.makeWindowControllers()
      let model = try #require(document.model)
      model.start()
      for _ in 0..<100 where continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
      let pending = try #require(continuation)
      document.close()
      pending.resume(returning: AVMutableComposition())
      await Task.yield()
      #expect(model.player == nil)
    }

    @Test("UCT-1019.5: Retained UI and model do not keep the Document alive")
    func retainedModelAndPaneDoNotRetainDocument() async throws {
      let url = try makeRecordingTestPackage()
      defer { try? FileManager.default.removeItem(at: url) }
      weak var weakDocument: RecordPlayerDocument?
      var loadCount = 0
      let (model, controller, pane) = try autoreleasepool {
        let document = try openRecordingTestDocument(url)
        weakDocument = document
        document.assetLoader = { _, _ in
          loadCount += 1
          return AVMutableComposition()
        }
        document.makeWindowControllers()
        let model = try #require(document.model)
        let controller = try #require(document.windowControllers.first)
        let pane = try #require(controller.window?.contentViewController)
        document.close()
        document.removeWindowController(controller)
        controller.document = nil
        return (model, controller, pane)
      }
      for _ in 0..<100 where weakDocument != nil { try await Task.sleep(for: .milliseconds(10)) }
      #expect(weakDocument == nil)
      model.start()
      for _ in 0..<10 where model.isLoading { try await Task.sleep(for: .milliseconds(10)) }
      #expect(loadCount == 0)
      #expect(pane.view != nil)
      model.stop()
      controller.close()
    }

  }
}
