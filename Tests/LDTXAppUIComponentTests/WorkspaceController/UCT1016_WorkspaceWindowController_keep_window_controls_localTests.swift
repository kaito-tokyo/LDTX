// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXBackgroundSegmentation
import LDTXDeviceRegistry
import LDTXProgram
import LDTXProgramRuntime
import LDTXProtos
import LDTXTaskQueue
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletModel
@testable import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import LDTXYouTubeRTMPS
import Observation
import Security
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1016: keep-window-controls-local", .serialized)
  @MainActor
  struct UCT1016WorkspaceWindowControllerIntegrationTestSuite {
    @Test("Stream-key candidate loss clears only the editing choice")
    func streamKeyDraftDoesNotReplaceRestoredAssignment() throws {
      let suite = "StreamKeyDraft.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let data = WorkspaceAppletData(
        userDefaults: defaults,
        keychainClient: .init(
          copyMatching: { _, _ in errSecItemNotFound }, update: { _, _ in errSecSuccess },
          add: { _, _ in errSecSuccess }))
      var assignment: String? = "restored"
      var draft: String?
      let assigned = Binding<String?>(get: { assignment }, set: { assignment = $0 })
      let choice = Binding<String?>(get: { draft }, set: { draft = $0 })
      let inspector = WorkspaceOutputInspector(
        outputSettings: .constant(.init()), externalID: UUID(),
        isOutputActive: false, appletData: data, reportError: { _ in })
      _ = inspector.body
      #expect(draft == nil)
      #expect(assignment == "restored")
      draft = "removed"
      draft = WorkspaceSelectionRules.reconciled(draft, availableIDs: [])
      #expect(draft == nil)
      #expect(assignment == "restored")
      #expect(throws: WorkspaceSelectionError.self) {
        try inspector.selectStreamKey("missing", assignment: assigned, draft: choice)
      }
      #expect(assignment == "restored")
      try inspector.selectStreamKey(nil, assignment: assigned, draft: choice)
      #expect(assignment == nil)
    }
    private static var controller: NSDocumentController {
      UIComponentTestEnvironment.documentController
    }
    init() { _ = Self.controller }

    @Test("UCT-1016.1: Operations fail safely when a runtime is unavailable")
    func programInspectorRejectsSelectionWithoutRuntime() {
      let service = WorkspaceStateService(definition: .init(), preferences: .init())
      let inspector = WorkspaceProgramsInspector(
        stateService: service, appletData: WorkspaceAppletData())
      #expect(throws: WorkspaceSelectionError.self) { try inspector.selectProgram(internalID: 1) }

    }

    @Test("UCT-1016.2: Program choices are laid out vertically")
    func swiftUIProgramRadiosLayOutVertically() {
      _ = NSApplication.shared
      var first = Ldtx_Workspace_V4_ProgramDefinition()
      first.internalID = 11
      first.displayName = "First Program"
      var second = Ldtx_Workspace_V4_ProgramDefinition()
      second.internalID = 22
      second.displayName = "Second Program"
      let single = NSHostingView(
        rootView: WorkspaceProgramSelector(
          programs: [first], selection: .constant(11)))
      let pair = NSHostingView(
        rootView: WorkspaceProgramSelector(
          programs: [first, second], selection: .constant(22)))
      #expect(pair.fittingSize.height > single.fittingSize.height)
      #expect(pair.fittingSize.width < single.fittingSize.width * 2)
    }

    @Test("UCT-1016.3: An empty Program selector remains visible")
    func emptyProgramSelectorHasVisibleContent() {
      _ = NSApplication.shared
      let empty = NSHostingView(
        rootView: WorkspaceProgramSelector(programs: [], selection: .constant(nil)))
      #expect(empty.fittingSize.width > 0)
      #expect(empty.fittingSize.height > 0)
      #expect(empty.fittingSize.height <= 40)
    }

    @Test(
      "UCT-1016.4: Program selection resolves current definitions without rewriting restored IDs")
    func programPickerSelectionResolvesDefinitionWithoutRewritingSavedIDs() throws {
      _ = NSApplication.shared
      let suite = "ProgramPicker." + UUID().uuidString
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let data = WorkspaceAppletData(userDefaults: defaults)
      let url = URL(fileURLWithPath: "/tmp/ProgramPicker-\(UUID()).ldtxworkspace")
      let state = WorkspaceStateService(definition: .init(), preferences: .init())
      state.localStateURL = url
      let window = makeWorkspaceTestWindow(
        stateService: state, appletData: data)
      defer { window.close() }
      let content = window.contentPane
      let inspector = WorkspaceProgramsInspector(
        stateService: state, appletData: data)
      #expect(inspector.programSelection.wrappedValue == nil)
      var first = Ldtx_Workspace_V4_ProgramDefinition()
      first.internalID = 11
      first.displayName = "Same Name"
      var second = first
      second.internalID = 22
      state.workspaceDefinition.programs = [first, second]
      #expect(inspector.programSelection.wrappedValue == 11)
      data.updateState(for: url) { $0.selectedProgramInternalID = 22 }
      // AppKit Content and the Inspector resolve the same local selection.
      #expect(
        content.appletData.selectedProgram(
          in: content.stateService.workspaceDefinition, for: content.stateService.localStateURL)?
          .internalID == 22)
      let binding = inspector.programSelection
      #expect(!inspector.canSelectProgram)
      #expect(binding.wrappedValue == 22)
      // This standalone Store has no runtime. A rejected write preserves selection.
      binding.wrappedValue = 11
      #expect(binding.wrappedValue == 22)
      #expect(data.state(for: url).selectedProgramInternalID == 22)
      state.workspaceDefinition.programs = [first]
      #expect(binding.wrappedValue == 11)
      #expect(inspector.programSelection.wrappedValue == 11)
      #expect(data.state(for: url).selectedProgramInternalID == 22)
      state.workspaceDefinition.programs = []
      #expect(inspector.programSelection.wrappedValue == nil)
      #expect(binding.wrappedValue == nil)
      binding.wrappedValue = nil
      #expect(
        content.appletData.selectedProgram(
          in: content.stateService.workspaceDefinition, for: content.stateService.localStateURL)
          == nil)
      #expect(data.state(for: url).selectedProgramInternalID == 22)
    }

    @Test("UCT-1016.5: Sidebar selection starts empty and remains Window local")
    func sidebarSelectionStartsEmptyAndStaysWindowLocal() throws {
      _ = NSApplication.shared
      let state = WorkspaceStateService(definition: .init(), preferences: .init())
      let other = WorkspaceStateService(definition: .init(), preferences: .init())
      let window = makeWorkspaceTestWindow(stateService: state)
      let second = makeWorkspaceTestWindow(stateService: other)
      defer {
        window.close()
        second.close()
      }
      #expect(state.inspectorSelector == nil)
      state.inspectorSelector = .init(kind: .workspacePrograms)
      #expect(state.inspectorSelector != nil)
      #expect(other.inspectorSelector == nil)
    }

    @Test("UCT-1016.6: Physical assignments change only on explicit valid selection")
    func physicalAssignmentsAreDisplayOnlyUntilAnExplicitValidCommit() throws {
      let suite = "WorkspaceSelectionTests." + UUID().uuidString
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let data = WorkspaceAppletData(userDefaults: defaults)
      let state = WorkspaceStateService(definition: .init(), preferences: .init())
      state.workspaceDefinition.videoComponents = [
        WorkspaceResourceFactory.makeVFXSource(id: 101, name: "Camera"),
        WorkspaceResourceFactory.makeVFXSource(id: 102, name: "Other Camera"),
      ]
      let unavailable = WorkspacePhysicalDeviceID.avCaptureDevice(uniqueID: "missing-camera")
      data.setPhysicalDeviceID(unavailable, for: 101)
      data.setPhysicalDeviceID(unavailable, for: 102)
      let field = WorkspacePhysicalDeviceField(
        title: "Camera", internalID: 101, isAudio: false, stateService: state,
        appletData: data, deviceRegistry: DeviceRegistryService())
      let before = state.workspaceDefinition
      _ = field.body
      #expect(data.physicalDeviceID(for: 101) == unavailable)
      #expect(state.workspaceDefinition == before)
      state.isOutputActive = true
      #expect(throws: WorkspaceSelectionError.self) { try field.applySelection(nil) }
      #expect(data.physicalDeviceID(for: 101) == unavailable)
      state.isOutputActive = false
      try field.applySelection(nil)
      #expect(data.physicalDeviceID(for: 101) == nil)
      #expect(data.physicalDeviceID(for: 102) == unavailable)
      #expect(WorkspaceAppletData(userDefaults: defaults).physicalDeviceID(for: 101) == nil)
      #expect(throws: WorkspaceSelectionError.self) { try field.applySelection(unavailable) }
      #expect(data.physicalDeviceID(for: 101) == nil)
      state.workspaceDefinition.videoComponents.removeAll()
      #expect(throws: WorkspaceSelectionError.self) { try field.applySelection(nil) }
    }

    @Test("Workspace native sidebar toggle restores width and stays Window local")
    func nativeSidebarToggleRestoresWidth() async throws {
      let first = makeWorkspaceTestWindow()
      let second = makeWorkspaceTestWindow()
      defer {
        first.close()
        second.close()
      }
      await settleWorkspaceToolbar(first)
      let item = try #require(
        first.toolbar?.items.first {
          $0.itemIdentifier.rawValue == "workspace.toggleSidebar"
        })
      let split = first.splitViewController
      #expect(first.contentViewController === first.content)
      #expect(split.parent === first.content)
      split.view.layoutSubtreeIfNeeded()
      split.splitView.setPosition(280, ofDividerAt: 0)
      let width = split.splitView.arrangedSubviews[0].frame.width
      try performWorkspaceToolbarAction(item)
      try await Task.sleep(for: .milliseconds(500))
      #expect(split.splitViewItems[0].isCollapsed)
      #expect(!second.splitViewController.splitViewItems[0].isCollapsed)
      try performWorkspaceToolbarAction(item)
      try await Task.sleep(for: .milliseconds(500))
      split.view.layoutSubtreeIfNeeded()
      #expect(!split.splitViewItems[0].isCollapsed)
      #expect(abs(split.splitView.arrangedSubviews[0].frame.width - width) <= 1)
      split.toggleInspector(nil)
      #expect(!first.stateService.isInspectorVisible)
      split.toggleInspector(nil)
      #expect(first.stateService.isInspectorVisible)
    }

    @Test("UCT-1016.7: Toolbar pane toggles restore widths in their own Window")
    func toolbarActionsRestoreWidthsAndStayWithinTheirWindow() async throws {
      _ = NSApplication.shared
      let first = makeWorkspaceTestWindow()
      let second = makeWorkspaceTestWindow()
      defer {
        first.close()
        second.close()
      }
      await settleWorkspaceToolbar(first)
      let toolbar = try #require(first.toolbar)
      #expect(first.toolbarStyle == .unified)
      #expect(first.titleVisibility == .visible)
      let screenshot = try #require(
        toolbar.items.first {
          $0.itemIdentifier.rawValue == "workspace.captureScreenshots"
        })
      #expect(screenshot.isEnabled)
      let split = first.splitViewController
      let other = second.splitViewController
      split.view.layoutSubtreeIfNeeded()
      let sidebarWidth = split.splitView.arrangedSubviews[0].frame.width
      #expect((240...260).contains(sidebarWidth))
      let contentWidth =
        split.splitView.bounds.width - sidebarWidth - 340
        - 2 * split.splitView.dividerThickness
      for (pane, expectedWidth) in zip(
        split.splitView.arrangedSubviews, [sidebarWidth, contentWidth, 340.0])
      {
        #expect(
          abs(pane.frame.width - expectedWidth) <= 1,
          "Actual: \(pane.frame.width), expected: \(expectedWidth)")
      }
      for (identifier, index) in [
        (NSToolbarItem.Identifier("workspace.toggleSidebar"), 0),
        (.init("workspace.toggleInspector"), 2),
      ] {
        let item = try #require(toolbar.items.first { $0.itemIdentifier == identifier })
        #expect(item.target === split)
        #expect(!item.autovalidates)
        let width = split.splitView.arrangedSubviews[index].frame.width
        try performWorkspaceToolbarAction(item)
        try await Task.sleep(for: .milliseconds(350))
        #expect(split.splitViewItems[index].isCollapsed)
        #expect(!other.splitViewItems[index].isCollapsed)
        try performWorkspaceToolbarAction(item)
        try await Task.sleep(for: .milliseconds(350))
        split.view.layoutSubtreeIfNeeded()
        #expect(!split.splitViewItems[index].isCollapsed)
        #expect(
          abs(split.splitView.arrangedSubviews[index].frame.width - width) <= 1,
          "Pane \(index): \(split.splitView.arrangedSubviews[index].frame.width), before \(width)")
      }
    }

    @Test("Declared Inspector separator survives toolbar configuration changes")
    func declaredInspectorSeparatorSurvivesUpdates() async throws {
      let state = WorkspaceSidebarPreviewFixtures.makeUIState(
        inspectorSelector: .init(kind: .ocrVision, internalID: 10))
      let window = makeWorkspaceTestWindow(stateService: state)
      defer { window.close() }
      await settleWorkspaceToolbar(window)
      let toolbar = try #require(window.toolbar)
      for selector in [
        .init(kind: .workspaceCanvas),
        .init(kind: .ocrVision, internalID: 10),
      ] as [WorkspaceInspectorSelector] {
        state.inspectorSelector = selector
        await settleWorkspaceToolbar(window)
        #expect(window.toolbar === toolbar)
        let items = toolbar.items
        let separator = try #require(
          items.firstIndex {
            $0.itemIdentifier == .inspectorTrackingSeparator
          })
        #expect(items[separator] is NSTrackingSeparatorToolbarItem)
        #expect(items.filter { $0.itemIdentifier == .inspectorTrackingSeparator }.count == 1)
        #expect(items[..<separator].contains { $0.itemIdentifier == .flexibleSpace })
        #expect(items[(separator + 1)...].contains { $0.itemIdentifier == .flexibleSpace })
      }
      let separatorItem = try #require(
        toolbar.items.first { $0.itemIdentifier == .inspectorTrackingSeparator })
      let applyID = NSToolbarItem.Identifier("workspace.inspector.apply")
      #expect(!toolbar.items.contains { $0.itemIdentifier == applyID })
      window.splitViewController.toggleInspector(nil)
      await settleWorkspaceToolbar(window)
      #expect(!state.isInspectorVisible)
      #expect(!toolbar.items.contains { $0.itemIdentifier == applyID })
      window.splitViewController.toggleInspector(nil)
      await settleWorkspaceToolbar(window)
      #expect(state.isInspectorVisible)
      #expect(!toolbar.items.contains { $0.itemIdentifier == applyID })
      #expect(
        toolbar.items.first { $0.itemIdentifier == .inspectorTrackingSeparator } === separatorItem)
    }

    @Test("An unsaved Workspace disables output without disabling editing")
    func unsavedOutputIsUnavailable() async throws {
      let document = WorkspaceDocument()
      let dispatcher = ToolbarDispatcher()
      let window = makeWorkspaceTestWindow(
        stateService: document.stateService, dispatcher: dispatcher, documentContext: document)
      defer { window.close() }
      await settleWorkspaceToolbar(window)
      let toggle = try #require(
        window.toolbar?.items.first {
          $0.itemIdentifier.rawValue == "workspace.startPauseOutput"
        })
      #expect(!window.validateToolbarItem(toggle))
      window.toggleOutput()
      await drainWorkspaceTestTasks()
      #expect(dispatcher.actions.isEmpty)
      document.stateService.workspaceDefinition.displayName = "Still editable"
      #expect(document.stateService.workspaceDefinition.displayName == "Still editable")
      #expect(document.fileURL == nil)
    }

    @Test("UCT-1016.8: Output buttons reflect state and invoke their own runtime")
    func outputButtonsReflectStateAndDispatchToTheirWindow() async throws {
      _ = NSApplication.shared
      let state = WorkspaceStateService(definition: .init(), preferences: .init())
      let dispatcher = ToolbarDispatcher()
      let otherDispatcher = ToolbarDispatcher()
      let first = makeWorkspaceTestWindow(stateService: state, dispatcher: dispatcher)
      let second = makeWorkspaceTestWindow(dispatcher: otherDispatcher)
      defer {
        first.close()
        second.close()
      }
      await settleWorkspaceToolbar(first)
      let items = try #require(first.toolbar).items
      let stop = try #require(items.first { $0.itemIdentifier.rawValue == "workspace.stopOutput" })
      let toggle = try #require(
        items.first { $0.itemIdentifier.rawValue == "workspace.startPauseOutput" })
      for (value, stopEnabled, toggleEnabled, label) in [
        (WorkspaceRecordingState.idle, false, true, "Start Output"),
        (.starting, false, false, "Start Output"),
        (.recording, true, true, "Pause Output"),
        (.pausing, false, false, "Start Output"),
        (.paused, true, true, "Start Output"),
        (.stopping, false, false, "Start Output"),
        (.failed("Failure"), false, true, "Start Output"),
      ] {
        state.recordingState = value
        await settleWorkspaceToolbar(first)
        #expect(first.validateToolbarItem(stop) == stopEnabled)
        #expect(first.validateToolbarItem(toggle) == toggleEnabled)
        #expect(toggle.label == label)
        #expect(
          toggle.image?.tiffRepresentation
            == NSImage(
              systemSymbolName: value == .recording ? "pause.fill" : "play.fill",
              accessibilityDescription: nil)?.tiffRepresentation)
      }
      state.recordingState = .idle
      try performWorkspaceToolbarAction(toggle)
      await drainWorkspaceTestTasks()
      #expect(dispatcher.actions == ["start"])
      state.recordingState = .recording
      try performWorkspaceToolbarAction(toggle)
      await drainWorkspaceTestTasks()
      #expect(dispatcher.actions == ["start", "pause"])
      state.recordingState = .paused
      try performWorkspaceToolbarAction(stop)
      await drainWorkspaceTestTasks()
      #expect(dispatcher.actions == ["start", "pause", "stop"])
      state.recordingState = .pausing
      try performWorkspaceToolbarAction(toggle)
      await drainWorkspaceTestTasks()
      #expect(dispatcher.actions == ["start", "pause", "stop"])
      #expect(otherDispatcher.actions.isEmpty)
      state.recordingState = .idle
      dispatcher.failStart = true
      await settleWorkspaceToolbar(first)
      try performWorkspaceToolbarAction(toggle)
      await drainWorkspaceTestTasks()
      #expect(state.outputFailureMessage != nil)
    }

    @Test("UCT-1016.16: Screenshot results use a transient popover without changing output state")
    func screenshotFailureDoesNotPoisonOutput() async throws {
      let state = WorkspaceStateService(definition: .init(), preferences: .init())
      let dispatcher = ToolbarDispatcher()
      let window = makeWorkspaceTestWindow(stateService: state, dispatcher: dispatcher)
      window.orderFront(nil)
      window.screenshotResultPopover.animates = false
      defer { window.close() }
      state.isOutputActive = true
      state.isLocalRecording = true
      state.outputFailureMessage = "Existing output failure"
      await settleWorkspaceToolbar(window)
      let item = try #require(
        window.toolbar?.items.first {
          $0.itemIdentifier.rawValue == "workspace.captureScreenshots"
        })
      dispatcher.failScreenshot = true
      try performWorkspaceToolbarAction(item)
      #expect(window.screenshotResultPopover.isShown)
      #expect(window.screenshotResultPopover.behavior == .transient)
      let popoverWindow = try #require(
        window.screenshotResultPopover.contentViewController?.view.window)
      #expect(popoverWindow.frame.maxY <= window.frame.maxY)
      #expect(popoverWindow.frame.maxY >= window.frame.maxY - 70)
      #expect(state.outputFailureMessage == "Existing output failure")
      dispatcher.failScreenshot = false
      for count in [1, 2] {
        dispatcher.screenshotFiles = (0..<count).map {
          WorkspaceScreenshot(
            url: URL(fileURLWithPath: "/tmp/screenshot-\($0).png"),
            programCanvas: $0 == 0 ? .landscape : .portrait)
        }
        dispatcher.screenshotFiles.append(.init(url: URL(fileURLWithPath: "/tmp/source.png")))
        try performWorkspaceToolbarAction(item)
        #expect(window.screenshotResultPopover.isShown)
        let label = window.screenshotResultPopover.contentViewController?.view.accessibilityLabel()
        #expect(
          label == "Screenshots saved. Saved \(count) Program screenshot\(count == 1 ? "" : "s").")
        let controller = try #require(
          window.screenshotResultPopover.contentViewController
            as? NSHostingController<ScreenshotResultView>)
        #expect(controller.rootView.screenshots.count == 1)
        #expect(controller.rootView.screenshots.allSatisfy { $0.programCanvas == .landscape })
      }
      #expect(state.outputFailureMessage == "Existing output failure")
      dispatcher.failScreenshot = true
      try performWorkspaceToolbarAction(item)
      window.close()
      for _ in 0..<100 {
        if !window.screenshotResultPopover.isShown { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(!window.screenshotResultPopover.isShown)
    }

    @Test("UCT-1016.9: Screenshot actions remain available outside local recording")
    func screenshotToolbarActionsRemainAvailable() async throws {
      _ = NSApplication.shared
      let state = WorkspaceStateService(definition: .init(), preferences: .init())
      let dispatcher = ToolbarDispatcher()
      let window = makeWorkspaceTestWindow(stateService: state, dispatcher: dispatcher)
      defer { window.close() }
      await settleWorkspaceToolbar(window)
      for (id, expected) in [
        ("workspace.captureScreenshots", "screenshot")
      ] {
        let item = try #require(window.toolbar?.items.first { $0.itemIdentifier.rawValue == id })
        #expect(item.isEnabled)
        try performWorkspaceToolbarAction(item)
        #expect(dispatcher.actions == [expected])
        dispatcher.actions = []
        state.isOutputActive = true
        state.isLocalRecording = false
        #expect(item.isEnabled)
        state.isLocalRecording = true
        await settleWorkspaceToolbar(window)
        #expect(item.isEnabled)
        #expect(item.isEnabled)
        #expect(item.label != "Start Output")
        try performWorkspaceToolbarAction(item)
        #expect(dispatcher.actions == [expected])
        dispatcher.actions = []
        state.isOutputActive = false
        state.isLocalRecording = false
      }
    }

    @Test("UCT-1016.10: Program selection updates only the owning Window runtimes")
    func programSelectionUpdatesOwnedRuntimesAndStaysWindowLocal() async throws {
      let suite = "ProgramSelection.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let data = WorkspaceAppletData(userDefaults: defaults)
      let first = WorkspaceDocument()
      let second = WorkspaceDocument()
      defer {
        first.close()
        second.close()
      }
      first.stateService.workspaceDefinition.canvasConfiguration.landscapeProfileID =
        "sdr-landscape-1080p60"
      first.stateService.workspaceDefinition.canvasConfiguration.portraitProfileID =
        "sdr-portrait-1080p60"
      let firstWindow = WorkspaceWindowController(
        stateService: first.stateService,
        persistenceCoordinator: first.persistenceCoordinator, appletData: data,
        document: first)
      first.addWindowController(firstWindow)
      firstWindow.adoptDocumentURL(URL(fileURLWithPath: "/tmp/First-\(UUID()).ldtxworkspace"))
      let a = try firstWindow.windowRuntime.addProgram(displayName: "First")
      let b = try firstWindow.windowRuntime.addProgram(displayName: "Second")
      second.stateService.workspaceDefinition = first.stateService.workspaceDefinition
      second.stateService.workspacePreferences = first.stateService.workspacePreferences
      let secondWindow = WorkspaceWindowController(
        stateService: second.stateService,
        persistenceCoordinator: second.persistenceCoordinator, appletData: data,
        document: second)
      second.addWindowController(secondWindow)
      secondWindow.adoptDocumentURL(URL(fileURLWithPath: "/tmp/Second-\(UUID()).ldtxworkspace"))
      let savedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: savedRoot) }
      try await saveWorkspaceDocument(
        first, to: savedRoot.appendingPathComponent("First.ldtxworkspace"))
      try await saveWorkspaceDocument(
        second, to: savedRoot.appendingPathComponent("Second.ldtxworkspace"))
      try secondWindow.selectProgram(internalID: a)
      let landscape = try #require(firstWindow.windowRuntime.landscapeRuntime)
      let portrait = try #require(firstWindow.windowRuntime.portraitRuntime)
      let definition = first.stateService.workspaceDefinition
      first.stateService.inspectorSelector = .init(kind: .workspacePrograms)
      try firstWindow.selectProgram(internalID: b)
      #expect(firstWindow.windowRuntime.landscapeRuntime === landscape)
      #expect(firstWindow.windowRuntime.portraitRuntime === portrait)
      #expect(data.state(for: first.stateService.localStateURL!).selectedProgramInternalID == b)
      #expect(data.state(for: second.stateService.localStateURL!).selectedProgramInternalID == a)
      // Content is now the live AppKit controller connected to this document.
      #expect(
        data.selectedProgram(
          in: first.stateService.workspaceDefinition, for: first.stateService.localStateURL)?
          .internalID == b)
      #expect(first.stateService.inspectorSelector == .init(kind: .workspacePrograms))
      let inspector = WorkspaceProgramsInspector(
        stateService: first.stateService, appletData: data,
        runtimeActions: { firstWindow })
      #expect(inspector.canSelectProgram)
      #expect(inspector.programSelection.wrappedValue == b)
      #expect(second.stateService.inspectorSelector == nil)
      #expect(first.stateService.workspaceDefinition == definition)
      #expect(throws: (any Error).self) { try firstWindow.selectProgram(internalID: Int64.max) }
      try firstWindow.selectProgram(internalID: a)
      #expect(data.state(for: first.stateService.localStateURL!).selectedProgramInternalID == a)
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("Selection.ldtxworkspace")
      try await saveWorkspaceDocument(first, to: url)
      try firstWindow.selectProgram(internalID: b)
      await firstWindow.shutdown()
      first.close()
      let reopened = try await loadWorkspaceDocument(at: url)
      defer { reopened.close() }
      let reopenedWindow = WorkspaceWindowController(
        stateService: reopened.stateService,
        persistenceCoordinator: reopened.persistenceCoordinator, appletData: data,
        document: reopened)
      reopened.addWindowController(reopenedWindow)
      // Opening an existing file supplies its URL without moving transient window state.
      reopened.stateService.localStateURL = nil
      reopenedWindow.adoptDocumentURL(url)
      let reopenedInspector = WorkspaceProgramsInspector(
        stateService: reopened.stateService, appletData: data,
        runtimeActions: { reopenedWindow })
      #expect(data.state(for: url).selectedProgramInternalID == b)
      #expect(reopenedInspector.canSelectProgram)
      #expect(reopenedInspector.programSelection.wrappedValue == b)
      #expect(
        data.selectedProgram(
          in: reopened.stateService.workspaceDefinition, for: reopened.stateService.localStateURL)?
          .internalID == b)
      #expect(reopened.stateService.inspectorSelector == nil)
      await reopenedWindow.shutdown()
      await secondWindow.shutdown()
    }

    @Test("UCT-1016.11: Shared device assignments update open Windows and stop after shutdown")
    func sharedAssignmentsUpdateBothWindowsAndStopObservingAfterShutdown() async throws {
      let suite = "WorkspaceDocumentAssignments.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let data = WorkspaceAppletData(userDefaults: defaults)
      let first = WorkspaceDocument()
      let second = WorkspaceDocument()
      defer {
        first.close()
        second.close()
      }
      first.stateService.workspaceDefinition.canvasConfiguration.landscapeProfileID =
        "sdr-landscape-1080p60"
      first.stateService.workspaceDefinition.canvasConfiguration.portraitProfileID =
        "sdr-portrait-1080p60"
      let firstWindow = WorkspaceWindowController(
        stateService: first.stateService,
        persistenceCoordinator: first.persistenceCoordinator, appletData: data,
        document: first)
      first.addWindowController(firstWindow)
      let input = try firstWindow.windowRuntime.addVFXSource(displayName: "Camera")
      firstWindow.adoptDocumentURL(URL(fileURLWithPath: "/tmp/First-\(UUID()).ldtxworkspace"))
      let program = try firstWindow.windowRuntime.addProgram(displayName: "Main")
      try firstWindow.windowRuntime.setVideoLayerOrder(
        [input], forProgramInternalID: program, target: .landscape)
      data.updateState(for: first.stateService.localStateURL!) {
        $0.selectedProgramInternalID = program
      }
      second.stateService.workspaceDefinition = first.stateService.workspaceDefinition
      second.stateService.workspacePreferences = first.stateService.workspacePreferences
      let secondWindow = WorkspaceWindowController(
        stateService: second.stateService,
        persistenceCoordinator: second.persistenceCoordinator, appletData: data,
        document: second)
      second.addWindowController(secondWindow)
      secondWindow.adoptDocumentURL(URL(fileURLWithPath: "/tmp/Second-\(UUID()).ldtxworkspace"))
      data.updateState(for: second.stateService.localStateURL!) {
        $0.selectedProgramInternalID = program
      }
      let savedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: savedRoot) }
      try await saveWorkspaceDocument(
        first, to: savedRoot.appendingPathComponent("First.ldtxworkspace"))
      try await saveWorkspaceDocument(
        second, to: savedRoot.appendingPathComponent("Second.ldtxworkspace"))
      let firstRuntime = try #require(firstWindow.windowRuntime.landscapeRuntime)
      let secondRuntime = try #require(secondWindow.windowRuntime.landscapeRuntime)
      data.setPhysicalDeviceID(.avCaptureDevice(uniqueID: "test-camera"), for: input)
      for _ in 0..<100
      where firstRuntime.programState.read({ $0?.cameraIDsByInputKey["v4-\(input)"] })
        != "test-camera"
        || secondRuntime.programState.read({ $0?.cameraIDsByInputKey["v4-\(input)"] })
          != "test-camera"
      {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(
        firstRuntime.programState.read { $0?.cameraIDsByInputKey["v4-\(input)"] } == "test-camera")
      #expect(
        secondRuntime.programState.read { $0?.cameraIDsByInputKey["v4-\(input)"] } == "test-camera")
      firstWindow.adoptDocumentURL(
        URL(fileURLWithPath: "/tmp/MovedAssignments-\(UUID()).ldtxworkspace"))
      try await Task.sleep(for: .milliseconds(20))
      #expect(
        try firstWindow.windowRuntime.runtimeProjection(
          programInternalID: program, target: .landscape
        )
        .configuration.cameraIDsByInputKey["v4-\(input)"] == "test-camera")
      await firstWindow.shutdown()
      data.setPhysicalDeviceID(nil, for: input)
      for _ in 0..<100
      where secondRuntime.programState.read({ $0?.cameraIDsByInputKey.isEmpty }) != true {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(
        firstRuntime.programState.read { $0?.cameraIDsByInputKey["v4-\(input)"] } == "test-camera")
      #expect(secondRuntime.programState.read { $0?.cameraIDsByInputKey.isEmpty } == true)
      await secondWindow.shutdown()
    }

    @Test("UCT-1016.12: Dock badges follow registered runtime controllers")
    func dockBadgeFollowsRegisteredControllers() async {
      let dockTile = NSApplication.shared.dockTile
      let originalBadge = dockTile.badgeLabel
      let first = WorkspaceDocument()
      let second = WorkspaceDocument()
      _ = first.controller
      _ = second.controller
      defer {
        first.close()
        second.close()
        dockTile.badgeLabel = originalBadge
      }
      first.stateService.isOutputActive = true
      first.stateService.isOutputActive = true
      second.stateService.isOutputActive = true
      await drainWorkspaceTestTasks()
      #expect(dockTile.badgeLabel == "REC")
      first.stateService.isOutputActive = false
      await drainWorkspaceTestTasks()
      #expect(dockTile.badgeLabel == "REC")
      second.stateService.isOutputActive = false
      await drainWorkspaceTestTasks()
      #expect(dockTile.badgeLabel == nil)
      first.stateService.isOutputActive = true
      second.stateService.isOutputActive = true
      first.close()
      await drainWorkspaceTestTasks()
      #expect(dockTile.badgeLabel == "REC")
      second.close()
      await drainWorkspaceTestTasks()
      #expect(dockTile.badgeLabel == nil)
      #expect(dockTile.badgeLabel == nil)
    }

    @Test("UCT-1016.13: Sidebar additions affect their own Document and persist only on Save")
    func sidebarAdditionsStayInTheirDocumentAndPersistOnlyOnSave() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "AddSheets-\(UUID())")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("Show.ldtxworkspace")
      let document = WorkspaceDocument()
      let other = WorkspaceDocument()
      defer {
        document.close()
        other.close()
      }
      try await saveWorkspaceDocument(document, to: url)
      let savedDefinition = document.stateService.workspaceDefinition
      let otherDefinition = other.stateService.workspaceDefinition
      var draft = WorkspaceAddDraft()
      draft.name = "Camera"
      draft.componentKind = .vfxSource
      let camera = WorkspaceAddDeviceOption(
        id: .avCaptureDevice(uniqueID: "test-camera"), name: "Camera", width: 1920, height: 1080)
      draft.physicalDeviceID = camera.id
      let inputID = try WorkspaceResourceAddition.add(
        sheet: .videoComponent, draft: draft, devices: [camera], stateService: document.stateService
      )
      draft.name = "Color"
      draft.componentKind = .solidColor
      try WorkspaceResourceAddition.add(
        sheet: .videoComponent, draft: draft, devices: [], stateService: document.stateService)
      draft.name = "OCR"
      draft.videoComponentID = inputID
      try WorkspaceResourceAddition.add(
        sheet: .vision, draft: draft, devices: [], stateService: document.stateService)
      #expect(other.stateService.workspaceDefinition == otherDefinition)
      #expect(document.hasTestModelChanges)
      #expect(try WorkspaceBundleReaderV4(at: url).read().definition == savedDefinition)
      let expected = document.stateService.workspaceDefinition
      try await saveWorkspaceDocument(document, to: url, operation: .saveOperation)
      #expect(!document.hasTestModelChanges)
      let reopened = try await loadWorkspaceDocument(at: url)
      defer { reopened.close() }
      #expect(reopened.stateService.workspaceDefinition == expected)
      #expect(
        reopened.stateService.workspaceDefinition.visions.first?.ocrVision.videoComponentInternalID
          == inputID
      )
    }

    @Test("UCT-1016.14: Sidebar Preview uses its provided state")
    func workspaceSidebarUsesPreviewState() {
      let stateService = WorkspaceSidebarPreviewFixtures.makeUIState()
      let sidebar = WorkspaceSidebar(
        stateService: stateService,
        deviceRegistry: DeviceRegistryService(),
        appletData: WorkspaceAppletData())

      #expect(stateService.workspaceDefinition.displayName == "Workspace Sidebar Preview")
      _ = sidebar.body
    }
    @Test(
      "UCT-1016.15: Sidebar additions require a live Document",
      arguments: [WorkspaceAddSheet.device, .videoComponent, .vision])
    func workspaceSidebarRejectsAdditionWithoutLiveDocument(sheet: WorkspaceAddSheet) {
      let stateService = WorkspaceSidebarPreviewFixtures.makeUIState()
      let definition = stateService.workspaceDefinition
      let selection = stateService.inspectorSelector
      let data = WorkspaceAppletData()
      let assignments = data.physicalDeviceIDsByResourceInternalID
      let sidebar = WorkspaceSidebar(
        stateService: stateService,
        deviceRegistry: DeviceRegistryService(), appletData: data)
      var draft = WorkspaceAddDraft()
      draft.name = "New component"
      draft.componentKind = .solidColor

      #expect(!sidebar.canAddResource)
      do {
        try sidebar.addResource(sheet, draft: draft)
        Issue.record("Addition must require a live document")
      } catch {
        #expect(error.localizedDescription == "The Workspace document is unavailable.")
      }
      #expect(stateService.workspaceDefinition == definition)
      #expect(stateService.inspectorSelector == selection)
      #expect(data.physicalDeviceIDsByResourceInternalID == assignments)
    }
  }
}
