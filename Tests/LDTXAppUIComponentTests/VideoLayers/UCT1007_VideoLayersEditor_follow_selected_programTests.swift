// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletInterface
@testable import LDTXWorkspaceAppletUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1007: follow-selected-program", .serialized)
  @MainActor
  struct UCT1007VideoLayersEditorIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }
    @Test("UCT-1007.1: Preview constraints preserve editor size")
    func previewConstraintsPreserveEditorSize() {
      let fixture = VideoLayersTestFixture()
      let editor = fixture.makeEditor()
      editor.update(
        definition: .init(), programPreferences: .init(), layerIDs: [1, 2],
        canvasWidth: 1920, canvasHeight: 1080)
      NSLayoutConstraint.activate([
        editor.view.widthAnchor.constraint(equalToConstant: 720),
        editor.view.heightAnchor.constraint(equalToConstant: 360),
      ])
      #expect(editor.view.fittingSize == NSSize(width: 720, height: 360))
    }

    @Test("UCT-1007.2: Editor rows use available width")
    func editorRowsUseAvailableWidth() throws {
      let service = WorkspaceStoreService(definition: .init(), preferences: .init())
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 100
      program.landscapeVideoLayerInternalIds = [1, 2]
      service.definition.programs = [program]
      let editor = VideoLayersEditor(storeService: service, target: .landscape)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 360),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.contentViewController = editor
      window.setContentSize(NSSize(width: 720, height: 360))
      window.contentView?.layoutSubtreeIfNeeded()
      let row = try #require(
        editor.table.view(atColumn: 0, row: 0, makeIfNecessary: true)
          as? VideoLayersTableRow)
      row.layoutSubtreeIfNeeded()
      #expect(editor.table.enclosingScrollView == nil)
      #expect(editor.table.frame.width >= 690)
      #expect(editor.table.frame.height >= editor.table.intrinsicContentSize.height - 0.5)
      #expect(editor.table.rect(ofRow: 1).maxY <= editor.table.bounds.height + 0.5)
      #expect(row.frame.width >= 670)
      #expect(row.rootView.state === row.state)
      #expect(row.rootView.canvasWidth == 1920)
      #expect(row.rootView.canvasHeight == 1080)
    }

    @Test("UCT-1007.3: Editor owns observation without loading view until used")
    func editorOwnsObservationWithoutLoadingViewUntilUsed() async throws {
      let storeService = WorkspaceStoreService(definition: .init(), preferences: .init())
      let editor = VideoLayersEditor(storeService: storeService, target: .landscape)
      #expect(!editor.isViewLoaded)
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 100
      program.landscapeVideoLayerInternalIds = [1]
      storeService.definition.programs = [program]
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentViewController = editor
      window.orderFront(nil)
      defer { window.close() }
      window.contentView?.layoutSubtreeIfNeeded()
      #expect(editor.table.layerIDs == [1])
      storeService.definition.programs[0].landscapeVideoLayerInternalIds = [1, 2]
      for _ in 0..<50 {
        if editor.table.layerIDs == [1, 2] { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(editor.table.layerIDs == [1, 2])
    }

    @Test("UCT-1007.4: Hidden video tab uses latest state when shown")
    func hiddenVideoTabUsesLatestStateWhenShown() async throws {
      _ = NSApplication.shared
      let service = WorkspaceStoreService(definition: .init(), preferences: .init())
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 100
      program.landscapeVideoLayerInternalIds = [1]
      program.portraitVideoLayerInternalIds = [2]
      service.definition.programs = [program]
      let landscape = VideoLayersEditor(storeService: service, target: .landscape)
      let portrait = VideoLayersEditor(storeService: service, target: .portrait)
      let tabs = NSTabViewController()
      tabs.addTabViewItem(NSTabViewItem(viewController: landscape))
      tabs.addTabViewItem(NSTabViewItem(viewController: portrait))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 400), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentViewController = tabs
      window.orderFront(nil)
      defer { window.close() }
      service.definition.programs[0].portraitVideoLayerInternalIds = [2, 3]
      tabs.selectedTabViewItemIndex = 1
      for _ in 0..<100 {
        if portrait.table.layerIDs == [2, 3] { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(portrait.table.layerIDs == [2, 3])
    }

    @Test("UCT-1007.5: Editor reuses rows and refreshes save connections")
    func editorReusesRowsAndRefreshesSaveConnections() throws {
      let fixture = VideoLayersTestFixture()
      let editor = fixture.makeEditor()
      var saved: [UInt64] = []
      editor.update(
        definition: .init(), programPreferences: .init(), layerIDs: [1, 2],
        canvasWidth: 1920, canvasHeight: 1080,
        onCommitTransform: { id, value in
          saved.append(id)
          return value
        })
      let row = try #require(editor.table.rows[1])
      #expect(row.delegate === editor)
      row.state.strings[0] = "960"
      row.state.hasUnconfirmedChanges = true
      editor.update(
        definition: .init(), programPreferences: .init(), layerIDs: [2, 1],
        canvasWidth: 1920, canvasHeight: 1080,
        onCommitTransform: { id, value in
          saved.append(id + 100)
          return value
        })
      #expect(editor.table.rows[1] === row)
      #expect(row.state.strings[0] == "960")
      row.state.onCommit()
      #expect(saved == [101])
      editor.update(
        definition: .init(), programPreferences: .init(), layerIDs: [2, 1],
        canvasWidth: 1080, canvasHeight: 1920)
      let replacement = try #require(editor.table.rows[1])
      #expect(replacement !== row)
      #expect(replacement.rootView.canvasWidth == 1080)
      #expect(replacement.rootView.canvasHeight == 1920)
      #expect(!row.state.hasUnconfirmedChanges)
    }

    @Test("UCT-1007.6: Resolves and updates names from definition")
    func resolvesAndUpdatesNamesFromDefinition() throws {
      let fixture = VideoLayersTestFixture()
      var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
      var device = Ldtx_Workspace_V4_VfxSourceComponent()
      device.internalID = 1
      device.displayName = "Camera"
      var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      wrapper.vfxSource = device
      definition.videoComponents = [wrapper]
      var clock = Ldtx_Workspace_V4_ClockComponent()
      clock.internalID = 3
      clock.displayName = "Clock"
      var component = Ldtx_Workspace_V4_VideoComponentWrapper()
      component.clock = clock
      definition.videoComponents.append(component)
      let editor = fixture.makeEditor()
      let table = editor.table
      editor.update(
        definition: definition, programPreferences: .init(), layerIDs: [1, 2, 3], canvasWidth: 1920,
        canvasHeight: 1080)
      let row = try #require(table.rows[1])
      #expect(row.state.name == "Camera")
      #expect(table.rows[3]?.state.name == "Clock")
      definition.videoComponents[0].vfxSource.displayName = "Renamed"
      editor.update(
        definition: definition, programPreferences: .init(), layerIDs: [1, 2, 3], canvasWidth: 1920,
        canvasHeight: 1080)
      #expect(table.rows[1] === row)
      #expect(row.state.name == "Renamed")
      #expect(table.rows[2]?.state.name == "Missing Video Layer")
    }

    @Test("UCT-1007.7: Changing program discards transform draft")
    func changingProgramDiscardsTransformDraft() throws {
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 1
      program.landscapeVideoLayerInternalIds = [1, 2, 3]
      var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
      definition.programs = [program]
      let state = WorkspaceStoreService(definition: definition, preferences: .init())
      let content = VideoLayersEditor(
        storeService: state, target: .landscape)
      let editor = content
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentViewController = content
      defer {
        window.close()
      }
      content.refresh()
      let old = try #require(editor.table.rows[1])
      old.state.strings[0] = "draft"
      old.state.hasUnconfirmedChanges = true
      state.definition.programs[0].internalID = 2
      content.refresh()
      #expect(editor.table.rows[1] !== old)
      #expect(editor.table.rows[1]?.state.hasUnconfirmedChanges == false)
    }

  }
}
