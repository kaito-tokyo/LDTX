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

@MainActor
private final class RecordingTestDocumentController: NSDocumentController {
  override func documentClass(forType typeName: String) -> AnyClass? {
    typeName == RecordPlayerDocument.typeName ? RecordPlayerDocument.self : WorkspaceDocument.self
  }
  override func typeForContents(of url: URL) throws -> String {
    url.pathExtension == "ldtxrecord" ? RecordPlayerDocument.typeName : "tokyo.kaito.ldtx.workspace"
  }
}

@Suite(.serialized)
@MainActor
struct RecordPlayerDocumentSystemTestSuite {
  private static let controller = RecordingTestDocumentController()

  private func package() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("ldtxrecord")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    try RecordingPackageInfo.data(
      identifier: "document-test", mainMediaFile: "main.mp4", audioTracks: [], formatVersion: 2
    )
    .write(to: url.appendingPathComponent(RecordingPackageInfo.fileName))
    try Data().write(to: url.appendingPathComponent("main.mp4"))
    try Data().write(to: url.appendingPathComponent("manifest.mpd"))
    return url
  }

  private func document(_ url: URL) throws -> RecordPlayerDocument {
    _ = Self.controller
    _ = NSApplication.shared
    return try RecordPlayerDocument(contentsOf: url, ofType: RecordPlayerDocument.typeName)
  }

  private func save(
    _ document: RecordPlayerDocument, to url: URL,
    operation: NSDocument.SaveOperationType = .saveOperation
  ) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      document.save(to: url, ofType: RecordPlayerDocument.typeName, for: operation) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  @Test func malformedOptionalMarkersAllowPlaybackButCannotBeOverwritten() async throws {
    let url = try package()
    defer { try? FileManager.default.removeItem(at: url) }
    let markerURL = try RecordingMarkerStore(recordingDirectoryURL: url).createMarker(
      at: .zero, note: "Original")
    let malformed = Data([0xff, 0xfe])
    try malformed.write(to: markerURL)
    let document = try document(url)
    defer { document.close() }
    document.makeWindowControllers()
    #expect(document.model != nil)
    #expect(document.markers.isEmpty)
    try document.createMarker(note: "Pending", at: CMTime(seconds: 1, preferredTimescale: 600))
    do {
      try await save(document, to: url)
      Issue.record("Unreadable marker baseline must not be overwritten")
    } catch {}
    #expect(document.isDocumentEdited)
    #expect(try Data(contentsOf: markerURL) == malformed)
    #expect(throws: (any Error).self) {
      try document.revert(toContentsOf: url, ofType: RecordPlayerDocument.typeName)
    }
    #expect(document.markers.map(\.note) == ["Pending"])
    try Data("Repaired\n".utf8).write(to: markerURL)
    try document.revert(toContentsOf: url, ofType: RecordPlayerDocument.typeName)
    #expect(document.markers.map(\.note) == ["Repaired"])
    try document.createMarker(note: "New", at: CMTime(seconds: 1, preferredTimescale: 600))
    try await save(document, to: url)
    #expect(!document.isDocumentEdited)
  }

  @Test func legacyRegisteredTypeStillOpensAndSavesMarkers() async throws {
    let url = try package()
    defer { try? FileManager.default.removeItem(at: url) }
    _ = Self.controller
    let document = try RecordPlayerDocument(
      contentsOf: url, ofType: RecordingPackageInfo.legacyTypeIdentifier)
    defer { document.close() }
    try document.createMarker(note: "Legacy association", at: .zero)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      document.save(to: url, ofType: RecordingPackageInfo.legacyTypeIdentifier, for: .saveOperation)
      { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
    #expect(!document.isDocumentEdited)
    #expect(
      try RecordingMarkerStore(recordingDirectoryURL: url).markers().map(\.note) == [
        "Legacy association"
      ])
  }

  @Test func standardControllerOwnsAndReusesRecordingAlongsideWorkspace() async throws {
    let url = try package()
    defer { try? FileManager.default.removeItem(at: url) }
    let controller = Self.controller
    let workspace = try controller.makeUntitledDocument(ofType: "tokyo.kaito.ldtx.workspace")
    controller.addDocument(workspace)
    defer { workspace.close() }
    func open() async throws -> (NSDocument, Bool) {
      try await withCheckedThrowingContinuation { continuation in
        controller.openDocument(withContentsOf: url, display: false) { document, existing, error in
          if let error {
            continuation.resume(throwing: error)
          } else if let document {
            continuation.resume(returning: (document, existing))
          } else {
            continuation.resume(throwing: CocoaError(.fileReadUnknown))
          }
        }
      }
    }
    let (first, alreadyOpen) = try await open()
    defer { first.close() }
    let (second, reused) = try await open()
    #expect(first is RecordPlayerDocument)
    #expect(!alreadyOpen && reused)
    #expect(first === second)
    #expect(controller.documents.contains { $0 === first })
    #expect(controller.documents.contains { $0 === workspace })
  }

  @Test func editsStayInMemoryUntilSaveAndRevertPreservesPlaybackState() async throws {
    let url = try package()
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try document(url)
    defer { document.close() }
    document.makeWindowControllers()
    let model = try #require(document.model)
    let player = AVPlayer()
    model.player = player
    model.selectedCanvas = .portrait
    try document.createMarker(note: "Saved", at: .zero)
    #expect(document.isDocumentEdited)
    #expect(try RecordingMarkerStore(recordingDirectoryURL: url).markers().isEmpty)
    try await save(document, to: url)
    #expect(!document.isDocumentEdited)
    try document.deleteMarker(try #require(document.markers.first))
    #expect(
      document.validateUserInterfaceItem(
        NSMenuItem(
          title: "Revert", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")))
    try document.revert(toContentsOf: url, ofType: RecordPlayerDocument.typeName)
    #expect(document.markers.map(\.note) == ["Saved"])
    #expect(!document.isDocumentEdited)
    #expect(model.player === player)
    #expect(model.selectedCanvas == .portrait)
    #expect(
      document.windowControllers.first?.window?.restorationClass
        === RecordingTestDocumentController.self)
    document.close()
    #expect(model.player == nil)
  }

  @Test func closingCleanWindowClosesDocumentAndStopsPlayback() throws {
    let url = try package()
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try document(url)
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

  @Test func closeCancelKeepsPlaybackAndDiscardStopsIt() async throws {
    let url = try package()
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try document(url)
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
      withDelegate: probe, shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)),
      contextInfo: nil)
    try await clickSheetButton("Cancel", in: window)
    for _ in 0..<100 where probe.result == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(probe.result == false)
    #expect(model.player === player)
    #expect(document.isDocumentEdited)
    #expect(Self.controller.documents.contains { $0 === document })
    probe.result = nil
    document.canClose(
      withDelegate: probe, shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)),
      contextInfo: nil)
    try await clickSheetButton("Don’t Save", in: window)
    for _ in 0..<100 where probe.result == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(probe.result == true)
    document.close()
    #expect(model.player == nil)
    #expect(!Self.controller.documents.contains { $0 === document })
    #expect(try RecordingMarkerStore(recordingDirectoryURL: url).markers().isEmpty)
  }

  @Test func closeSaveUsesStandardSaveBeforeAllowingClosure() async throws {
    let url = try package()
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try document(url)
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
      withDelegate: probe, shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)),
      contextInfo: nil)
    try await clickSheetButton("Save", in: window)
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

  @Test func movedRecordingSavesPendingMarkersAndLoadsCurrentURL() async throws {
    let original = try package()
    let moved = original.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("ldtxrecord")
    defer {
      try? FileManager.default.removeItem(at: original)
      try? FileManager.default.removeItem(at: moved)
    }
    _ = try RecordingMarkerStore(recordingDirectoryURL: original).createMarker(
      at: .zero, note: "Saved")
    let document = try document(original)
    defer { document.close() }
    var loadedURLs: [URL] = []
    document.assetLoader = { url, _ in
      loadedURLs.append(url)
      return AVMutableComposition()
    }
    document.makeWindowControllers()
    let model = try #require(document.model)
    model.start()
    for _ in 0..<100 where model.isLoading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(loadedURLs == [original])
    try document.createMarker(note: "Pending", at: CMTime(seconds: 1, preferredTimescale: 1000))
    let player = model.player
    try FileManager.default.moveItem(at: original, to: moved)
    document.presentedItemDidMove(to: moved)
    for _ in 0..<100 where document.fileURL != moved {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(document.fileURL == moved)
    #expect(model.player === player)
    #expect(document.markers.map(\.note) == ["Saved", "Pending"])
    model.availableCanvases = [.landscape, .portrait]
    model.selectCanvas(.portrait)
    for _ in 0..<100 where loadedURLs.count < 2 || model.isLoading {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(loadedURLs == [original, moved])
    #expect(document.markers.map(\.note) == ["Saved", "Pending"])
    try await save(document, to: moved)
    #expect(!document.isDocumentEdited)
    #expect(
      try RecordingMarkerStore(recordingDirectoryURL: moved).markers().map(\.note) == [
        "Saved", "Pending",
      ])
    try document.createMarker(note: "Keep", at: CMTime(seconds: 2, preferredTimescale: 1000))
    try Data().write(to: moved.appendingPathComponent(".shield.json"))
    do {
      try await save(document, to: moved)
      Issue.record("Expected active recording save failure")
    } catch {}
    #expect(document.isDocumentEdited)
    #expect(document.markers.map(\.note) == ["Saved", "Pending", "Keep"])
  }

  @Test func retainedModelAndPaneDoNotRetainDocument() async throws {
    let url = try package()
    defer { try? FileManager.default.removeItem(at: url) }
    weak var weakDocument: RecordPlayerDocument?
    var loadCount = 0
    let (model, controller, pane) = try autoreleasepool {
      let document = try document(url)
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

  @Test func markerObservationTracksEditsAndRevertWithoutMakingReadsDirty() async throws {
    let url = try package()
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try document(url)
    defer { document.close() }
    let notifications = OSAllocatedUnfairLock(initialState: 0)
    func observeMarkers() {
      withObservationTracking {
        _ = document.markers
      } onChange: {
        notifications.withLock { $0 += 1 }
      }
    }
    observeMarkers()
    try document.createMarker(note: "Saved", at: .zero)
    #expect(notifications.withLock { $0 } == 1)
    #expect(document.isDocumentEdited)
    try await save(document, to: url)
    #expect(!document.isDocumentEdited)
    observeMarkers()
    try document.deleteMarker(try #require(document.markers.first))
    #expect(notifications.withLock { $0 } == 2)
    #expect(document.isDocumentEdited)
    observeMarkers()
    try document.revert(toContentsOf: url, ofType: RecordPlayerDocument.typeName)
    #expect(notifications.withLock { $0 } == 3)
    #expect(document.markers.map(\.note) == ["Saved"])
    #expect(!document.isDocumentEdited)
    observeMarkers()
    try await save(document, to: url)
    #expect(notifications.withLock { $0 } == 3)
    #expect(!document.isDocumentEdited)
  }

  @Test func hostedPanesObserveOneDocumentWithoutSharingOtherDocuments() async throws {
    let firstURL = try package()
    let secondURL = try package()
    defer {
      try? FileManager.default.removeItem(at: firstURL)
      try? FileManager.default.removeItem(at: secondURL)
    }
    let first = try document(firstURL)
    let second = try document(secondURL)
    defer {
      first.close()
      second.close()
    }
    let firstReference = DocumentReference(first)
    let secondReference = DocumentReference(second)
    let firstProbe = MarkerPaneProbe()
    let secondProbe = MarkerPaneProbe()
    let otherProbe = MarkerPaneProbe()
    let windows = [
      hostMarkerProbe(firstReference, probe: firstProbe),
      hostMarkerProbe(firstReference, probe: secondProbe),
      hostMarkerProbe(secondReference, probe: otherProbe),
    ]
    defer { for window in windows { window.close() } }
    for _ in 0..<100 where !firstProbe.appeared || !secondProbe.appeared || !otherProbe.appeared {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(firstProbe.appeared && secondProbe.appeared && otherProbe.appeared)
    try first.createMarker(note: "Shared", at: .zero)
    for _ in 0..<100 where firstProbe.notes != ["Shared"] || secondProbe.notes != ["Shared"] {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(firstProbe.notes == ["Shared"])
    #expect(secondProbe.notes == ["Shared"])
    #expect(otherProbe.notes.isEmpty)
    try await save(first, to: firstURL)
    try first.deleteMarker(try #require(first.markers.first))
    for _ in 0..<100 where !firstProbe.notes.isEmpty || !secondProbe.notes.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(firstProbe.notes.isEmpty && secondProbe.notes.isEmpty)
    try first.revert(toContentsOf: firstURL, ofType: RecordPlayerDocument.typeName)
    for _ in 0..<100 where firstProbe.notes != ["Shared"] || secondProbe.notes != ["Shared"] {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(firstProbe.notes == ["Shared"] && secondProbe.notes == ["Shared"])
    #expect(otherProbe.notes.isEmpty)
  }

  private func hostMarkerProbe(_ reference: DocumentReference, probe: MarkerPaneProbe) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(
      rootView:
        MarkerProbeView(probe: probe).environment(\.documentReference, reference))
    window.orderFront(nil)
    return window
  }

  private func clickSheetButton(_ title: String, in window: NSWindow) async throws {
    func find(_ view: NSView) -> NSButton? {
      if let button = view as? NSButton {
        let normalized = button.title.replacingOccurrences(of: "’", with: "'")
        let expected = title.replacingOccurrences(of: "’", with: "'")
        let japanese = ["Cancel": "キャンセル", "Save": "保存", "Don’t Save": "保存しない"][title]
        if normalized == expected || button.title == japanese { return button }
      }
      return view.subviews.lazy.compactMap { find($0) }.first
    }
    for _ in 0..<200 {
      if let content = window.attachedSheet?.contentView, let button = find(content) {
        button.performClick(nil)
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CocoaError(.userCancelled)
  }

  @Test func closeCancelsAssetLoadingBeforeItCanRestartPlayback() async throws {
    let url = try package()
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try document(url)
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

  @Test func failedSaveAndRevertKeepEditsAndUnsupportedActionsAreDisabled() async throws {
    let url = try package()
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try document(url)
    defer { document.close() }
    try document.createMarker(note: "Pending", at: .zero)
    try Data().write(to: url.appendingPathComponent(".shield.json"))
    do {
      try await save(document, to: url)
      Issue.record("Expected save failure")
    } catch {}
    #expect(document.isDocumentEdited)
    #expect(document.markers.map(\.note) == ["Pending"])
    let invalid = url.appendingPathComponent("missing")
    #expect(throws: (any Error).self) {
      try document.revert(toContentsOf: invalid, ofType: RecordPlayerDocument.typeName)
    }
    #expect(document.markers.map(\.note) == ["Pending"])
    #expect(document.isDocumentEdited)
    do {
      try await save(document, to: invalid, operation: .saveAsOperation)
      Issue.record("Expected Save As failure")
    } catch {}
    #expect(document.autosavingFileType == nil)
    for action in [
      #selector(NSDocument.saveAs(_:)), #selector(NSDocument.saveTo(_:)),
      #selector(NSDocument.duplicate(_:)),
      #selector(NSDocument.rename(_:)), #selector(NSDocument.move(_:)),
      #selector(NSDocument.moveToUbiquityContainer(_:)),
    ] {
      #expect(
        !document.validateUserInterfaceItem(
          NSMenuItem(title: "", action: action, keyEquivalent: "")))
    }
    #expect(document.fileURL == url)
  }
}

@MainActor
private final class CloseProbe: NSObject {
  var result: Bool?
  @objc func document(
    _ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?
  ) {
    result = shouldClose
  }
}

@MainActor
private final class MarkerPaneProbe {
  var appeared = false
  var notes: [String] = []
}

private struct MarkerProbeView: View {
  @Environment(\.documentReference) private var reference
  let probe: MarkerPaneProbe
  private var notes: [String] {
    (reference?.document as? RecordPlayerDocument)?.markers.map(\.note) ?? []
  }
  var body: some View {
    Text(notes.joined(separator: ", "))
      .onChange(of: notes, initial: true) { _, notes in
        probe.notes = notes
        probe.appeared = true
      }
  }
}
