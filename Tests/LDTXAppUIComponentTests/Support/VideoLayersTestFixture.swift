// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXCorelibs
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

@MainActor
final class VideoLayersTestFixture {
  let state = WorkspaceDocument(definition: .init(), preferences: .init())
  let data = WorkspaceAppletData()
  let editor: VideoLayersEditorState

  init(ids: [Int64] = [1, 2, 3]) {
    state.editWorkspace(undoManager: nil) { workspace in
      workspace.definition.programs = [.with { $0.internalID = 100 }]
    }
    state.editWorkspace(undoManager: nil) { workspace in
      workspace.definition.videoComponents = ids.map { id in
        .with {
          $0.videoComponent = .vfxSource(
            .with {
              $0.internalID = id
              $0.displayName = "Layer \(id)"
            })
        }
      }
    }
    state.editWorkspace(undoManager: nil) { workspace in
      workspace.preferences.landscapeProgramPreferences[100, default: .init()]
        .videoLayerInternalIds = ids
    }
    editor = VideoLayersEditorState(stateService: state, appletData: data, target: .landscape)
  }
  func update(ids: [Int64]) {
    state.editWorkspace(undoManager: nil) { workspace in
      workspace.preferences.landscapeProgramPreferences[100, default: .init()]
        .videoLayerInternalIds = ids
    }
    editor.synchronizeRows()
  }
}

@MainActor
func workspaceDescendants(_ view: NSView) -> [NSView] {
  [view] + view.subviews.flatMap { workspaceDescendants($0) }
}

@MainActor
func hostWorkspaceView<V: View>(_ root: V, width: CGFloat = 720, height: CGFloat = 400) -> NSWindow
{
  let window = NSWindow(contentViewController: NSHostingController(rootView: root))
  window.isReleasedWhenClosed = false
  window.setContentSize(.init(width: width, height: height))
  window.orderFront(nil)
  window.contentView?.layoutSubtreeIfNeeded()
  return window
}

@MainActor
func editWorkspaceField(_ field: NSTextField, text: String, window: NSWindow) throws {
  #expect(window.makeFirstResponder(field))
  let editor = try #require(field.currentEditor() as? NSTextView)
  editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
}
