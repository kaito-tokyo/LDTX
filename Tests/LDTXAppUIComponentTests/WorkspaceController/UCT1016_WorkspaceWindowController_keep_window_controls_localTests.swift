// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXDeviceRegistry
import LDTXProgram
import LDTXProtos
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletInterface
@testable import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import Observation
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1016: keep-window-controls-local", .serialized)
  @MainActor
  struct UCT1016WorkspaceWindowControllerIntegrationTestSuite {
    private static var controller: NSDocumentController {
      UIComponentTestEnvironment.documentController
    }
    init() { _ = Self.controller }

    @Test("UCT-1016.1: Operations fail safely when a runtime is unavailable")
    func storeRejectsOperationsWithoutRuntime() async {
      let service = WorkspaceStoreService(definition: .init(), preferences: .init())
      await #expect(throws: WorkspaceSelectionError.self) { try await service.startOutput() }
      #expect(throws: WorkspaceSelectionError.self) { try service.selectProgram(internalID: 1) }
      #expect(throws: WorkspaceSelectionError.self) { try service.captureScreenshots() }
      let ids: Set<String> = await withCheckedContinuation { continuation in
        service.synchronizeCaptureInputs(availableCameraIDs: []) { ids in
          continuation.resume(returning: ids)
        }
      }
      #expect(ids.isEmpty)
      service.synchronizeAudioMonitor()
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
      let state = WorkspaceStoreService(definition: .init(), preferences: .init())
      state.localStateURL = url
      let window = makeWorkspaceTestWindow(storeService: state, appletData: data)
      defer { window.close() }
      let content = window.contentPane
      let inspector = WorkspaceProgramsInspector(storeService: state, appletData: data)
      #expect(inspector.programSelection.wrappedValue == nil)
      var first = Ldtx_Workspace_V4_ProgramDefinition()
      first.internalID = 11
      first.displayName = "Same Name"
      var second = first
      second.internalID = 22
      state.definition.programs = [first, second]
      #expect(inspector.programSelection.wrappedValue == 11)
      data.updateState(for: url) { $0.selectedProgramInternalID = 22 }
      // The unhosted Content value has no document environment and must not read
      // local selection through the cached URL.
      #expect(content.storeService.selectedProgram?.internalID == 11)
      let binding = inspector.programSelection
      #expect(!inspector.canSelectProgram)
      #expect(binding.wrappedValue == 11)
      // A standalone Inspector has no live document environment. An attempted
      // edit must not change the cached local selection.
      binding.wrappedValue = 11
      #expect(binding.wrappedValue == 11)
      #expect(data.state(for: url).selectedProgramInternalID == 22)
      state.definition.programs = [first]
      #expect(binding.wrappedValue == 11)
      #expect(inspector.programSelection.wrappedValue == 11)
      #expect(data.state(for: url).selectedProgramInternalID == 22)
      state.definition.programs = []
      #expect(inspector.programSelection.wrappedValue == nil)
      #expect(binding.wrappedValue == nil)
      binding.wrappedValue = nil
      #expect(content.storeService.selectedProgram == nil)
      #expect(data.state(for: url).selectedProgramInternalID == 22)
    }

    @Test("UCT-1016.5: Sidebar selection starts empty and remains Window local")
    func sidebarSelectionStartsEmptyAndStaysWindowLocal() throws {
      _ = NSApplication.shared
      let state = WorkspaceStoreService(definition: .init(), preferences: .init())
      let other = WorkspaceStoreService(definition: .init(), preferences: .init())
      let window = makeWorkspaceTestWindow(storeService: state)
      let second = makeWorkspaceTestWindow(storeService: other)
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
      let state = WorkspaceStoreService(definition: .init(), preferences: .init())
      state.definition.videoComponents = [
        WorkspaceResourceFactory.makeVFXSource(id: 101, name: "Camera"),
        WorkspaceResourceFactory.makeVFXSource(id: 102, name: "Other Camera"),
      ]
      let unavailable = WorkspacePhysicalDeviceID.avCaptureDevice(uniqueID: "missing-camera")
      data.setPhysicalDeviceID(unavailable, for: 101)
      data.setPhysicalDeviceID(unavailable, for: 102)
      let field = WorkspacePhysicalDeviceField(
        title: "Camera", internalID: 101, isAudio: false, storeService: state,
        appletData: data, deviceRegistry: DeviceRegistryService())
      let before = state.definition
      _ = field.body
      #expect(data.physicalDeviceID(for: 101) == unavailable)
      #expect(state.definition == before)
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
      state.definition.videoComponents.removeAll()
      #expect(throws: WorkspaceSelectionError.self) { try field.applySelection(nil) }
    }

    @Test("UCT-1016.7: Toolbar pane toggles restore widths in their own Window")
    func toolbarActionsRestoreWidthsAndStayWithinTheirWindow() throws {
      _ = NSApplication.shared
      let first = makeWorkspaceTestWindow()
      let second = makeWorkspaceTestWindow()
      defer {
        first.close()
        second.close()
      }
      let toolbar = try #require(first.toolbar)
      #expect(toolbar.identifier == "WorkspaceV4Toolbar.AppKit.v1")
      #expect(first.toolbarStyle == .unified)
      #expect(first.titleVisibility == .visible)
      #expect(toolbar.displayMode == .iconOnly)
      let screenshot = try #require(
        toolbar.items.first {
          $0.itemIdentifier.rawValue == "workspace.captureScreenshots"
        })
      #expect(screenshot.isNavigational)
      #expect(first.styleMask.contains(.fullSizeContentView))
      #expect(
        toolbar.items.map(\.itemIdentifier) == [
          .init("workspace.sidebar"), .sidebarTrackingSeparator,
          .init("workspace.stopOutput"), .init("workspace.toggleOutput"),
          .init("workspace.captureScreenshots"),
          .flexibleSpace,
          .inspectorTrackingSeparator, .init("workspace.inspectorTitle"),
          .flexibleSpace, .init("workspace.inspector"),
        ])
      #expect(first.contentLayoutRect.size == NSSize(width: 1062, height: 700))
      let split = try #require(first.contentViewController as? PaneSplitViewController)
      let other = try #require(second.contentViewController as? PaneSplitViewController)
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
        (NSToolbarItem.Identifier("workspace.sidebar"), 0), (.init("workspace.inspector"), 2),
      ] {
        let item = try #require(toolbar.items.first { $0.itemIdentifier == identifier })
        let action = try #require(item.action)
        let width = split.splitView.arrangedSubviews[index].frame.width
        #expect(item.target === split)
        #expect(NSApp.sendAction(action, to: item.target, from: item))
        #expect(split.splitViewItems[index].isCollapsed)
        #expect(!other.splitViewItems[index].isCollapsed)
        #expect(NSApp.sendAction(action, to: item.target, from: item))
        split.view.layoutSubtreeIfNeeded()
        #expect(!split.splitViewItems[index].isCollapsed)
        #expect(abs(split.splitView.arrangedSubviews[index].frame.width - width) <= 1)
      }
    }

    @Test("Inspector toolbar title follows selection and collapse")
    func inspectorToolbarTitleFollowsSelectionAndCollapse() async throws {
      let state = WorkspaceStoreService(definition: .init(), preferences: .init())
      state.inspectorSelector = .init(kind: .workspaceOutput)
      let window = makeWorkspaceTestWindow(storeService: state)
      defer { window.close() }
      let toolbar = try #require(window.toolbar)
      let identifier = NSToolbarItem.Identifier("workspace.inspectorTitle")
      let label = try #require(toolbar.items.first { $0.itemIdentifier == identifier }?.view as? NSTextField)
      #expect(label.stringValue == String(localized: "Output"))
      state.inspectorSelector = .init(kind: .workspaceCanvas)
      for _ in 0..<100 {
        if label.stringValue == String(localized: "Canvas") { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(label.stringValue == String(localized: "Canvas"))
      let split = try #require(window.contentViewController as? PaneSplitViewController)
      split.toggleInspector(nil)
      #expect(!toolbar.items.contains { $0.itemIdentifier == identifier })
      state.inspectorSelector = .init(kind: .workspacePrograms)
      split.toggleInspector(nil)
      let reopened = try #require(toolbar.items.first { $0.itemIdentifier == identifier }?.view as? NSTextField)
      #expect(reopened.stringValue == String(localized: "Programs"))
    }

    @Test("UCT-1016.8: Output buttons reflect state and invoke their own runtime")
    func outputButtonsReflectStateAndDispatchToTheirWindow() async throws {
      _ = NSApplication.shared
      let state = WorkspaceStoreService(definition: .init(), preferences: .init())
      let dispatcher = ToolbarDispatcher()
      let otherDispatcher = ToolbarDispatcher()
      let first = makeWorkspaceTestWindow(storeService: state, dispatcher: dispatcher)
      let second = makeWorkspaceTestWindow(dispatcher: otherDispatcher)
      defer {
        first.close()
        second.close()
      }
      let items = try #require(first.toolbar).items
      let stop = try #require(items.first { $0.itemIdentifier.rawValue == "workspace.stopOutput" })
      let toggle = try #require(
        items.first { $0.itemIdentifier.rawValue == "workspace.toggleOutput" })
      #expect(stop.isNavigational)
      #expect(toggle.isNavigational)
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
        first.updateOutputToolbar()
        #expect(stop.isEnabled == stopEnabled)
        #expect(toggle.isEnabled == toggleEnabled)
        #expect(toggle.label == label)
        #expect(toggle.toolTip == label)
        #expect(toggle.image?.accessibilityDescription == label)
      }
      state.recordingState = .idle
      #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
      await drainWorkspaceTestTasks()
      #expect(dispatcher.actions == ["start"])
      state.recordingState = .recording
      #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
      await drainWorkspaceTestTasks()
      #expect(dispatcher.actions == ["start", "pause"])
      state.recordingState = .paused
      #expect(NSApp.sendAction(try #require(stop.action), to: stop.target, from: stop))
      await drainWorkspaceTestTasks()
      #expect(dispatcher.actions == ["start", "pause", "stop"])
      state.recordingState = .pausing
      #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
      await drainWorkspaceTestTasks()
      #expect(dispatcher.actions == ["start", "pause", "stop"])
      #expect(otherDispatcher.actions.isEmpty)
      state.recordingState = .idle
      dispatcher.failStart = true
      #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
      await drainWorkspaceTestTasks()
      #expect(state.outputFailureMessage != nil)
    }

    @Test("UCT-1016.16: Screenshot results use a transient popover without changing output state")
    func screenshotFailureDoesNotPoisonOutput() async throws {
      let state = WorkspaceStoreService(definition: .init(), preferences: .init())
      let dispatcher = ToolbarDispatcher()
      let window = makeWorkspaceTestWindow(storeService: state, dispatcher: dispatcher)
      window.orderFront(nil)
      window.screenshotResultPopover.animates = false
      defer { window.close() }
      state.isOutputActive = true
      state.isLocalRecording = true
      state.outputFailureMessage = "Existing output failure"
      window.updateOutputToolbar()
      let item = try #require(
        window.toolbar?.items.first {
          $0.itemIdentifier.rawValue == "workspace.captureScreenshots"
        })
      dispatcher.failScreenshot = true
      #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
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
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
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
      #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
      window.close()
      for _ in 0..<100 {
        if !window.screenshotResultPopover.isShown { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(!window.screenshotResultPopover.isShown)
    }

    @Test("UCT-1016.9: Screenshot actions remain available outside local recording")
    func screenshotToolbarActionsRemainAvailable() throws {
      _ = NSApplication.shared
      let state = WorkspaceStoreService(definition: .init(), preferences: .init())
      let dispatcher = ToolbarDispatcher()
      let window = makeWorkspaceTestWindow(storeService: state, dispatcher: dispatcher)
      defer { window.close() }
      for (id, expected) in [
        ("workspace.captureScreenshots", "screenshot")
      ] {
        let item = try #require(window.toolbar?.items.first { $0.itemIdentifier.rawValue == id })
        let action = try #require(item.action)
        #expect(window.validateToolbarItem(item))
        _ = NSApp.sendAction(action, to: item.target, from: item)
        #expect(dispatcher.actions == [expected])
        dispatcher.actions = []
        state.isOutputActive = true
        state.isLocalRecording = false
        #expect(window.validateToolbarItem(item))
        state.isLocalRecording = true
        window.updateOutputToolbar()
        #expect(window.validateToolbarItem(item))
        #expect(item.isEnabled)
        #expect(item.label != "Start Output")
        #expect(NSApp.sendAction(action, to: item.target, from: item))
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
      first.storeService.definition.canvasConfiguration.landscapeProfileID = "sdr-landscape-1080p60"
      first.storeService.definition.canvasConfiguration.portraitProfileID = "sdr-portrait-1080p60"
      let firstWindow = WorkspaceWindowController(
        storeService: first.storeService,
        persistenceCoordinator: first.persistenceCoordinator, appletData: data,
        documentReference: DocumentReference(first))
      first.addWindowController(firstWindow)
      let a = try firstWindow.windowRuntime.addProgram(displayName: "First")
      let b = try firstWindow.windowRuntime.addProgram(displayName: "Second")
      second.storeService.definition = first.storeService.definition
      second.storeService.preferences = first.storeService.preferences
      let secondWindow = WorkspaceWindowController(
        storeService: second.storeService,
        persistenceCoordinator: second.persistenceCoordinator, appletData: data,
        documentReference: DocumentReference(second))
      second.addWindowController(secondWindow)
      try secondWindow.selectProgram(internalID: a)
      let landscape = try #require(firstWindow.windowRuntime.landscapeRuntime)
      let portrait = try #require(firstWindow.windowRuntime.portraitRuntime)
      let definition = first.storeService.definition
      first.storeService.inspectorSelector = .init(kind: .workspacePrograms)
      try firstWindow.selectProgram(internalID: b)
      #expect(firstWindow.windowRuntime.landscapeRuntime === landscape)
      #expect(firstWindow.windowRuntime.portraitRuntime === portrait)
      #expect(data.state(for: first.storeService.localStateURL!).selectedProgramInternalID == b)
      #expect(data.state(for: second.storeService.localStateURL!).selectedProgramInternalID == a)
      // Content is now the live AppKit controller connected to this document.
      #expect(
        (firstWindow.window as? WorkspaceWindow)?.contentPane.storeService.selectedProgram?
          .internalID == b)
      #expect(first.storeService.inspectorSelector == .init(kind: .workspacePrograms))
      let inspector = WorkspaceProgramsInspector(storeService: first.storeService, appletData: data)
      #expect(!inspector.canSelectProgram)
      #expect(inspector.programSelection.wrappedValue == a)
      #expect(second.storeService.inspectorSelector == nil)
      #expect(first.storeService.definition == definition)
      #expect(throws: (any Error).self) { try firstWindow.selectProgram(internalID: UInt64.max) }
      for state: WorkspaceRecordingState in [.starting, .pausing, .stopping] {
        firstWindow.windowRuntime.setRecordingState(state)
        #expect(throws: (any Error).self) { try firstWindow.selectProgram(internalID: a) }
        #expect(data.state(for: first.storeService.localStateURL!).selectedProgramInternalID == b)
      }
      firstWindow.windowRuntime.setRecordingState(.paused)
      try firstWindow.selectProgram(internalID: a)
      first.removeWindowController(firstWindow)
      #expect(firstWindow.document == nil)
      #expect(throws: (any Error).self) { try firstWindow.selectProgram(internalID: b) }
      #expect(data.state(for: first.storeService.localStateURL!).selectedProgramInternalID == a)
      first.addWindowController(firstWindow)
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("Selection.ldtxworkspace")
      try await saveWorkspaceDocument(first, to: url)
      try firstWindow.selectProgram(internalID: b)
      await firstWindow.shutdown()
      first.close()
      let reopened = try WorkspaceDocument(contentsOf: url, ofType: "tokyo.kaito.ldtx.workspace")
      defer { reopened.close() }
      let reopenedWindow = WorkspaceWindowController(
        storeService: reopened.storeService,
        persistenceCoordinator: reopened.persistenceCoordinator, appletData: data,
        documentReference: DocumentReference(reopened))
      reopened.addWindowController(reopenedWindow)
      let reopenedInspector = WorkspaceProgramsInspector(
        storeService: reopened.storeService, appletData: data)
      #expect(data.state(for: url).selectedProgramInternalID == b)
      #expect(!reopenedInspector.canSelectProgram)
      #expect(reopenedInspector.programSelection.wrappedValue == a)
      #expect(
        (reopenedWindow.window as? WorkspaceWindow)?.contentPane.storeService.selectedProgram?
          .internalID == b)
      #expect(reopened.storeService.inspectorSelector == nil)
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
      first.storeService.definition.canvasConfiguration.landscapeProfileID = "sdr-landscape-1080p60"
      first.storeService.definition.canvasConfiguration.portraitProfileID = "sdr-portrait-1080p60"
      let firstWindow = WorkspaceWindowController(
        storeService: first.storeService,
        persistenceCoordinator: first.persistenceCoordinator, appletData: data,
        documentReference: DocumentReference(first))
      first.addWindowController(firstWindow)
      let input = try firstWindow.windowRuntime.addVFXSource(displayName: "Camera")
      let program = try firstWindow.windowRuntime.addProgram(displayName: "Main")
      try firstWindow.windowRuntime.setVideoLayerOrder(
        [input], forProgramInternalID: program, target: .landscape)
      data.updateState(for: first.storeService.localStateURL!) {
        $0.selectedProgramInternalID = program
      }
      second.storeService.definition = first.storeService.definition
      second.storeService.preferences = first.storeService.preferences
      let secondWindow = WorkspaceWindowController(
        storeService: second.storeService,
        persistenceCoordinator: second.persistenceCoordinator, appletData: data,
        documentReference: DocumentReference(second))
      second.addWindowController(secondWindow)
      data.updateState(for: second.storeService.localStateURL!) {
        $0.selectedProgramInternalID = program
      }
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
      first.presentedItemDidMove(
        to: URL(fileURLWithPath: "/tmp/MovedAssignments-\(UUID()).ldtxworkspace"))
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

    @Test("UCT-1016.12: Dock badges follow registered Documents")
    func dockBadgeFollowsRegisteredDocuments() {
      let dockTile = NSApplication.shared.dockTile
      let originalBadge = dockTile.badgeLabel
      let controller = NSDocumentController.shared
      let first = WorkspaceDocument()
      let second = WorkspaceDocument()
      controller.addDocument(first)
      controller.addDocument(second)
      defer {
        first.close()
        second.close()
        dockTile.badgeLabel = originalBadge
      }
      first.storeService.isOutputActive = true
      first.storeService.isOutputActive = true
      second.storeService.isOutputActive = true
      #expect(dockTile.badgeLabel == "REC")
      first.storeService.isOutputActive = false
      #expect(dockTile.badgeLabel == "REC")
      second.storeService.isOutputActive = false
      #expect(dockTile.badgeLabel == nil)
      first.storeService.isOutputActive = true
      second.storeService.isOutputActive = true
      first.close()
      #expect(dockTile.badgeLabel == "REC")
      second.close()
      #expect(dockTile.badgeLabel == nil)
      #expect(!controller.documents.contains { $0 === first || $0 === second })
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
      let savedDefinition = document.storeService.definition
      let otherDefinition = other.storeService.definition
      var draft = WorkspaceAddDraft()
      draft.name = "Camera"
      draft.componentKind = .vfxSource
      let inputID = try WorkspaceResourceAddition.add(
        sheet: .videoComponent, draft: draft, devices: [], storeService: document.storeService)
      draft.name = "Color"
      draft.componentKind = .solidColor
      try WorkspaceResourceAddition.add(
        sheet: .videoComponent, draft: draft, devices: [], storeService: document.storeService)
      draft.name = "OCR"
      draft.videoComponentID = inputID
      try WorkspaceResourceAddition.add(
        sheet: .vision, draft: draft, devices: [], storeService: document.storeService)
      #expect(other.storeService.definition == otherDefinition)
      #expect(document.isDocumentEdited)
      #expect(try WorkspaceBundleReaderV4(at: url).read().definition == savedDefinition)
      let expected = document.storeService.definition
      try await saveWorkspaceDocument(document, to: url, operation: .saveOperation)
      #expect(!document.isDocumentEdited)
      let reopened = try WorkspaceDocument(contentsOf: url, ofType: "tokyo.kaito.ldtx.workspace")
      defer { reopened.close() }
      #expect(reopened.storeService.definition == expected)
      #expect(
        reopened.storeService.definition.visions.first?.ocrVision.videoComponentInternalID
          == inputID
      )
    }

    @Test("UCT-1016.14: Sidebar Preview uses its provided state")
    func workspaceSidebarUsesPreviewState() {
      let storeService = WorkspaceSidebarPreviewFixtures.makeUIState()
      let sidebar = WorkspaceSidebar(
        storeService: storeService, deviceRegistry: DeviceRegistryService(),
        appletData: WorkspaceAppletData())

      #expect(storeService.definition.displayName == "Workspace Sidebar Preview")
      _ = sidebar.body
    }
    @Test(
      "UCT-1016.15: Sidebar additions require a live Document",
      arguments: [WorkspaceAddSheet.device, .videoComponent, .vision])
    func workspaceSidebarRejectsAdditionWithoutLiveDocument(sheet: WorkspaceAddSheet) {
      let storeService = WorkspaceSidebarPreviewFixtures.makeUIState()
      let definition = storeService.definition
      let selection = storeService.inspectorSelector
      let data = WorkspaceAppletData()
      let assignments = data.physicalDeviceIDsByResourceInternalID
      let sidebar = WorkspaceSidebar(
        storeService: storeService, deviceRegistry: DeviceRegistryService(), appletData: data)
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
      #expect(storeService.definition == definition)
      #expect(storeService.inspectorSelector == selection)
      #expect(data.physicalDeviceIDsByResourceInternalID == assignments)
    }
  }
}
