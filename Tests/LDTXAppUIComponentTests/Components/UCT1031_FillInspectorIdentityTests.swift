// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProtos
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1031: Fill Inspector identity", .serialized)
  @MainActor
  struct UCT1031FillInspectorIdentityIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    @Test("Fill inspectors edit the component with the requested internal ID", arguments: 0..<4)
    func editsByInternalID(_ kind: Int) async throws {
      let storeAppletData = WorkspaceAppletData()
      let store = WorkspaceDocument(definition: .init(), preferences: .init())
      let component: Ldtx_Workspace_V4_VideoComponentWrapper
      let root: AnyView
      switch kind {
      case 0:
        component = WorkspaceResourceFactory.makeSolidColor(id: 11, name: "Source")
        store.editWorkspace(undoManager: nil) { workspace in
          workspace.definition.videoComponents = [component]
        }
        root = AnyView(
          SolidColorFillVideoComponentInspector(
            stateService: store, appletData: storeAppletData, videoComponentID: 11))
      case 1:
        component = WorkspaceResourceFactory.makeLinearGradient(id: 11, name: "Source")
        store.editWorkspace(undoManager: nil) { workspace in
          workspace.definition.videoComponents = [component]
        }
        root = AnyView(
          LinearGradientFillVideoComponentInspector(
            stateService: store, appletData: storeAppletData, videoComponentID: 11))
      case 2:
        component = WorkspaceResourceFactory.makeRadialGradient(id: 11, name: "Source")
        store.editWorkspace(undoManager: nil) { workspace in
          workspace.definition.videoComponents = [component]
        }
        root = AnyView(
          RadialGradientFillVideoComponentInspector(
            stateService: store, appletData: storeAppletData, videoComponentID: 11))
      default:
        component = WorkspaceResourceFactory.makeConicGradient(id: 11, name: "Source")
        store.editWorkspace(undoManager: nil) { workspace in
          workspace.definition.videoComponents = [component]
        }
        root = AnyView(
          ConicGradientFillVideoComponentInspector(
            stateService: store, appletData: storeAppletData, videoComponentID: 11))
      }
      store.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents.append(
          WorkspaceResourceFactory.makeSolidColor(id: 21, name: "Other"))
      }
      let hosting = NSHostingView(rootView: root.frame(width: 480, height: 800))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 800),
        styleMask: .titled, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      window.contentView = hosting
      hosting.layoutSubtreeIfNeeded()
      func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
      }
      let field = try #require(
        fields(hosting).first { $0.isEditable && $0.stringValue == "Source" })
      #expect(window.makeFirstResponder(field))
      let editor = try #require(field.currentEditor() as? NSTextView)
      editor.insertText(
        "Renamed", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
      editor.insertNewline(nil)
      try await Task.sleep(for: .milliseconds(100))
      #expect(store.workspaceDefinition.videoComponents[0].internalID == 11)
      #expect(store.workspaceDefinition.videoComponents[0].displayName == "Renamed")
      #expect(store.workspaceDefinition.videoComponents[1].displayName == "Other")
    }
  }
}
