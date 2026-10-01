// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AppKit
@testable import LDTXRecordPlayerApplet
import LDTXRecording
import LDTXWorkspaceAppletController
import Testing

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

  @Test func failedSaveAndRevertKeepEditsAndUnsupportedOperationsFail() async throws {
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
    #expect(throws: RecordingMarkerError.unsupportedOperation) { try document.duplicate() }
    #expect(document.autosavingFileType == nil)
    for action in [
      #selector(NSDocument.saveAs(_:)), #selector(NSDocument.duplicate(_:)),
      #selector(NSDocument.rename(_:)), #selector(NSDocument.move(_:)),
    ] {
      #expect(
        !document.validateUserInterfaceItem(
          NSMenuItem(title: "", action: action, keyEquivalent: "")))
    }
    await withCheckedContinuation { continuation in
      document.move(to: invalid) { error in
        #expect(error != nil)
        continuation.resume()
      }
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
