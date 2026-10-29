// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXCorelibs
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

enum FillKind: String, CaseIterable, Sendable, Codable {
  case solid, linearGradient, radialGradient, conicGradient
}

extension AppUIComponentTestSuite.Shard2 {
  @Suite("UCT-1031: Fill Inspector identity", .serialized)
  @MainActor
  struct UCT1031FillInspectorIdentityIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    @Test(
      "LUB-1048: Fill inspectors edit the component with the requested internal ID",
      arguments: FillKind.allCases)
    fileprivate func editsByInternalID(_ kind: FillKind) async throws {
      let storeAppletData = WorkspaceAppletData()
      let store = WorkspaceDocument(definition: .init(), preferences: .init())
      let component: Ldtx_Workspace_V4_VideoComponentWrapper
      let root: AnyView
      switch kind {
      case .solid:
        component = WorkspaceResourceFactory.makeSolidColor(id: 11, name: "Source")
        store.editWorkspace(undoManager: nil) { workspace in
          workspace.definition.videoComponents = [component]
        }
        root = AnyView(
          SolidColorFillVideoComponentInspector(
            stateService: store, appletData: storeAppletData, videoComponentID: 11))
      case .linearGradient:
        component = WorkspaceResourceFactory.makeLinearGradient(id: 11, name: "Source")
        store.editWorkspace(undoManager: nil) { workspace in
          workspace.definition.videoComponents = [component]
        }
        root = AnyView(
          LinearGradientFillVideoComponentInspector(
            stateService: store, appletData: storeAppletData, videoComponentID: 11))
      case .radialGradient:
        component = WorkspaceResourceFactory.makeRadialGradient(id: 11, name: "Source")
        store.editWorkspace(undoManager: nil) { workspace in
          workspace.definition.videoComponents = [component]
        }
        root = AnyView(
          RadialGradientFillVideoComponentInspector(
            stateService: store, appletData: storeAppletData, videoComponentID: 11))
      case .conicGradient:
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

extension AppUIComponentTestSuite.Shard2 {
  @Suite("Fill Inspector document bindings", .serialized)
  @MainActor
  struct FillInspectorBindingIntegrationTestSuite {
    private struct Controls {
      let name: Binding<String>
      let colors: [Binding<Color>]
      let geometry: [Binding<Ldtx_Workspace_V4_Rational32>]
    }

    private func controls(kind: FillKind, document: WorkspaceDocument, undo: UndoManager)
      -> Controls
    {
      let data = WorkspaceAppletData()
      switch kind {
      case .solid:
        let view = SolidColorFillVideoComponentInspector(
          stateService: document, appletData: data, videoComponentID: 11)
        return Controls(
          name: view.componentBinding(\.displayName, initial: "", undoManager: undo),
          colors: [view.colorBinding(\.extendedSrgbColor, initial: .clear, undoManager: undo)],
          geometry: [])
      case .linearGradient:
        let view = LinearGradientFillVideoComponentInspector(
          stateService: document, appletData: data, videoComponentID: 11)
        return Controls(
          name: view.componentBinding(\.displayName, initial: "", undoManager: undo),
          colors: [
            view.colorBinding(\.startExtendedSrgbColor, initial: .clear, undoManager: undo),
            view.colorBinding(\.endExtendedSrgbColor, initial: .clear, undoManager: undo),
          ],
          geometry: [
            view.componentBinding(\.startX, initial: .init(), undoManager: undo),
            view.componentBinding(\.startY, initial: .init(), undoManager: undo),
            view.componentBinding(\.endX, initial: .init(), undoManager: undo),
            view.componentBinding(\.endY, initial: .init(), undoManager: undo),
          ])
      case .radialGradient:
        let view = RadialGradientFillVideoComponentInspector(
          stateService: document, appletData: data, videoComponentID: 11)
        return Controls(
          name: view.componentBinding(\.displayName, initial: "", undoManager: undo),
          colors: [
            view.colorBinding(\.innerExtendedSrgbColor, initial: .clear, undoManager: undo),
            view.colorBinding(\.outerExtendedSrgbColor, initial: .clear, undoManager: undo),
          ],
          geometry: [
            view.componentBinding(\.centerX, initial: .init(), undoManager: undo),
            view.componentBinding(\.centerY, initial: .init(), undoManager: undo),
            view.componentBinding(\.innerRadius, initial: .init(), undoManager: undo),
            view.componentBinding(\.outerRadius, initial: .init(), undoManager: undo),
          ])
      case .conicGradient:
        let view = ConicGradientFillVideoComponentInspector(
          stateService: document, appletData: data, videoComponentID: 11)
        return Controls(
          name: view.componentBinding(\.displayName, initial: "", undoManager: undo),
          colors: [
            view.colorBinding(\.startExtendedSrgbColor, initial: .clear, undoManager: undo),
            view.colorBinding(\.endExtendedSrgbColor, initial: .clear, undoManager: undo),
          ],
          geometry: [
            view.componentBinding(\.centerX, initial: .init(), undoManager: undo),
            view.componentBinding(\.centerY, initial: .init(), undoManager: undo),
            view.componentBinding(\.startAngleRadians, initial: .init(), undoManager: undo),
          ])
      }
    }

    private func document(kind: FillKind) -> WorkspaceDocument {
      let source: Ldtx_Workspace_V4_VideoComponentWrapper
      switch kind {
      case .solid:
        source = WorkspaceResourceFactory.makeSolidColor(id: 11, name: "Source")
      case .linearGradient:
        source = WorkspaceResourceFactory.makeLinearGradient(id: 11, name: "Source")
      case .radialGradient:
        source = WorkspaceResourceFactory.makeRadialGradient(id: 11, name: "Source")
      case .conicGradient:
        source = WorkspaceResourceFactory.makeConicGradient(id: 11, name: "Source")
      }
      let document = WorkspaceDocument(definition: .init(), preferences: .init())
      document.editWorkspace(undoManager: nil) {
        $0.definition.videoComponents = [
          source, WorkspaceResourceFactory.makeSolidColor(id: 21, name: "Other"),
        ]
      }
      return document
    }

    @Test(
      "LUB-1048: Retained fill bindings follow Undo, Redo and subsequent edits",
      arguments: FillKind.allCases)
    fileprivate func followsHistory(kind: FillKind) throws {
      let document = document(kind: kind)
      let undo = UndoManager()
      undo.groupsByEvent = false
      let controls = controls(kind: kind, document: document, undo: undo)
      let original = document.workspace
      let colors = controls.colors.map {
        Ldtx_Workspace_V4_Color(extendedSRGBSwiftUIColor: $0.wrappedValue)
      }
      let geometry = controls.geometry.map { $0.wrappedValue }
      undo.beginUndoGrouping()
      controls.name.wrappedValue = "Edited"
      for binding in controls.colors {
        binding.wrappedValue = Color(red: 0.75, green: 0.25, blue: 0.5, opacity: 0.6)
      }
      for binding in controls.geometry {
        binding.wrappedValue = .with {
          $0.set(num: 1, den: 4)
        }
      }
      undo.endUndoGrouping()
      let edited = document.workspace
      #expect(edited != original)
      undo.undo()
      #expect(document.workspace == original)
      #expect(controls.name.wrappedValue == "Source")
      #expect(
        controls.colors.map { Ldtx_Workspace_V4_Color(extendedSRGBSwiftUIColor: $0.wrappedValue) }
          == colors)
      #expect(controls.geometry.map { $0.wrappedValue } == geometry)
      #expect(undo.canRedo)
      undo.redo()
      #expect(document.workspace == edited)
      #expect(controls.name.wrappedValue == "Edited")
      #expect(
        controls.geometry.allSatisfy {
          $0.wrappedValue == .with { $0.set(num: 1, den: 4) }
        })
      undo.undo()
      undo.beginUndoGrouping()
      controls.name.wrappedValue = "Next"
      undo.endUndoGrouping()
      var expected = original
      switch expected.definition.videoComponents[0].videoComponent {
      case .solidColorFill(var component):
        component.displayName = "Next"
        expected.definition.videoComponents[0].videoComponent = .solidColorFill(component)
      case .linearGradientFill(var component):
        component.displayName = "Next"
        expected.definition.videoComponents[0].videoComponent = .linearGradientFill(component)
      case .radialGradientFill(var component):
        component.displayName = "Next"
        expected.definition.videoComponents[0].videoComponent = .radialGradientFill(component)
      case .conicGradientFill(var component):
        component.displayName = "Next"
        expected.definition.videoComponents[0].videoComponent = .conicGradientFill(component)
      default:
        Issue.record("Unexpected fill component")
      }
      #expect(document.workspace == expected)
      #expect(!undo.canRedo)
    }

    @Test(
      "LUB-1048: Retained bindings reject output edits and deleted components",
      arguments: FillKind.allCases)
    fileprivate func rejectsUnavailableEdits(kind: FillKind) {
      let document = document(kind: kind)
      let undo = UndoManager()
      undo.groupsByEvent = false
      let controls = controls(kind: kind, document: document, undo: undo)
      let original = document.workspace
      func edit() {
        controls.name.wrappedValue = "Blocked"
        for binding in controls.colors { binding.wrappedValue = .red }
        for binding in controls.geometry { binding.wrappedValue = .init() }
      }
      document.isOutputActive = true
      edit()
      #expect(document.workspace == original)
      document.isOutputActive = false
      document.editWorkspace(undoManager: nil) { $0.definition.videoComponents.removeFirst() }
      let deleted = document.workspace
      edit()
      #expect(document.workspace == deleted)
      #expect(!undo.canUndo)
    }
  }
}
