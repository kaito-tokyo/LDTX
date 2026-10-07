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
func makeRecordingTestPackage() throws -> URL {
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

@MainActor
func openRecordingTestDocument(_ url: URL) throws -> RecordPlayerDocument {
  _ = UIComponentTestEnvironment.documentController
  _ = NSApplication.shared
  return try RecordPlayerDocument(contentsOf: url, ofType: RecordPlayerDocument.typeName)
}

@MainActor
func saveRecordingTestDocument(
  _ document: RecordPlayerDocument, to url: URL,
  operation: NSDocument.SaveOperationType = .saveOperation
) async throws {
  try await withCheckedThrowingContinuation {
    (continuation: CheckedContinuation<Void, Error>) in
    document.save(to: url, ofType: RecordPlayerDocument.typeName, for: operation) { error in
      if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
  }
}

@MainActor
func hostRecordingMarkerProbe(_ reference: DocumentReference, probe: MarkerPaneProbe) -> NSWindow {
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

@MainActor
func clickRecordingSheetButton(_ title: String, in window: NSWindow) async throws {
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

@MainActor
final class CloseProbe: NSObject {
  var result: Bool?
  @objc func document(
    _ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?
  ) {
    result = shouldClose
  }
}

@MainActor
final class MarkerPaneProbe {
  var appeared = false
  var notes: [String] = []
}

struct MarkerProbeView: View {
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
