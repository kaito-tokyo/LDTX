// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Combine
import LDTXVisionProgrammerApplet
import SwiftUI

struct AppCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  @StateObject private var documentCommands = DocumentCommandState()

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Open File…") { NSDocumentController.shared.openDocument(nil) }
        .keyboardShortcut("o")
      Button("Vision Programmer…") { openWindow(id: VisionProgrammerScene.id) }
    }
    CommandGroup(replacing: .saveItem) {
      Button("Close") { NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil) }
        .keyboardShortcut("w")
      Divider()
      Button("Save") { NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil) }
        .keyboardShortcut("s")
        .disabled(!documentCommands.canSave)
      Button("Save As…") { NSApp.sendAction(#selector(NSDocument.saveAs(_:)), to: nil, from: nil) }
        .keyboardShortcut("s", modifiers: [.command, .shift])
        .disabled(!documentCommands.canSaveAs)
      Button("Revert to Saved…") {
        NSApp.sendAction(#selector(NSDocument.revertToSaved(_:)), to: nil, from: nil)
      }
      .disabled(!documentCommands.canRevert)
    }
    CommandGroup(after: .help) {
      Button("Show Crash Reports in Finder") {
        NSWorkspace.shared.open(
          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Logs/DiagnosticReports", isDirectory: true))
      }
    }
  }
}

/// Keeps SwiftUI command availability aligned with AppKit's document validation.
@MainActor
private final class DocumentCommandState: ObservableObject {
  @Published private(set) var canSave = false
  @Published private(set) var canSaveAs = false
  @Published private(set) var canRevert = false
  private var observation: AnyCancellable?

  init() {
    observation = NotificationCenter.default.publisher(for: NSWindow.didUpdateNotification)
      .sink { [weak self] _ in
        MainActor.assumeIsolated { self?.update() }
      }
    update()
  }

  private func update() {
    func validate(_ action: Selector) -> Bool {
      guard let document = NSApp.target(forAction: action) as? NSDocument else { return false }
      return document.validateUserInterfaceItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }
    let save = validate(#selector(NSDocument.save(_:)))
    let saveAs = validate(#selector(NSDocument.saveAs(_:)))
    let revert = validate(#selector(NSDocument.revertToSaved(_:)))
    if canSave != save { canSave = save }
    if canSaveAs != saveAs { canSaveAs = saveAs }
    if canRevert != revert { canRevert = revert }
  }
}
