// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXBackgroundSegmentation
import LDTXCorelibs
import LDTXDeviceRegistry
import LDTXProgramRuntime
import LDTXTaskQueue
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletModel
@testable import LDTXWorkspaceAppletUI
import LDTXYouTubeRTMPS
import Observation
import Security
import SwiftUI
import Testing

extension AppUIComponentTestSuite.Shard2 {
  @Suite("keep-window-controls-local", .serialized)
  @MainActor
  struct WorkspaceWindowControlsIntegrationTestSuite {
    @Test("LUB-1066: Stream-key candidate loss clears only the editing choice")
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

    @Test("LUB-1049: Operations fail safely when a runtime is unavailable")
    func programInspectorRejectsSelectionWithoutRuntime() {
      let service = WorkspaceDocument(definition: .init(), preferences: .init())
      let inspector = WorkspaceProgramsInspector(
        stateService: service, appletData: WorkspaceAppletData())
      #expect(throws: WorkspaceSelectionError.self) { try inspector.selectProgram(internalID: 1) }

    }

    @Test("LUB-1049: Program choices are laid out vertically")
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

    @Test("LUB-1049: An empty Program selector remains visible")
    func emptyProgramSelectorHasVisibleContent() {
      _ = NSApplication.shared
      let empty = NSHostingView(
        rootView: WorkspaceProgramSelector(programs: [], selection: .constant(nil)))
      #expect(empty.fittingSize.width > 0)
      #expect(empty.fittingSize.height > 0)
      #expect(empty.fittingSize.height <= 40)
    }

    @Test(
      "LUB-1049: Program selection resolves current definitions without rewriting restored IDs"
    )
    func programPickerSelectionResolvesDefinitionWithoutRewritingSavedIDs() throws {
      _ = NSApplication.shared
      let suite = "ProgramPicker." + UUID().uuidString
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let data = WorkspaceAppletData(userDefaults: defaults)
      let url = URL(fileURLWithPath: "/tmp/ProgramPicker-\(UUID()).ldtxworkspace")
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      state.localStateURL = url
      let window = makeWorkspaceTestWindow(
        stateService: state, appletData: data)
      defer { window.close() }
      let content = window.contentPane
      let inspector = WorkspaceProgramsInspector(
        stateService: state, appletData: data)
      expectProgramSelection(inspector.programSelection.wrappedValue, equals: nil)
      var first = Ldtx_Workspace_V4_ProgramDefinition()
      first.internalID = 11
      first.displayName = "Same Name"
      var second = first
      second.internalID = 22
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.programs = [first, second]
      }
      expectProgramSelection(inspector.programSelection.wrappedValue, equals: 11)
      data.updateState(for: url) { $0.selectedProgramInternalID = 22 }
      // Content and the Inspector resolve the same local selection.
      expectProgramSelection(
        content.appletData.selectedProgram(
          in: content.stateService.workspaceDefinition, for: content.stateService.localStateURL)?
          .internalID, equals: 22)
      let binding = inspector.programSelection
      #expect(!inspector.canSelectProgram)
      expectProgramSelection(binding.wrappedValue, equals: 22)
      // This standalone Store has no runtime. A rejected write preserves selection.
      binding.wrappedValue = 11
      expectProgramSelection(binding.wrappedValue, equals: 22)
      expectProgramSelection(data.state(for: url).selectedProgramInternalID, equals: 22)
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.programs = [first]
      }
      expectProgramSelection(binding.wrappedValue, equals: 11)
      expectProgramSelection(inspector.programSelection.wrappedValue, equals: 11)
      expectProgramSelection(data.state(for: url).selectedProgramInternalID, equals: 22)
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.programs = []
      }
      expectProgramSelection(inspector.programSelection.wrappedValue, equals: nil)
      expectProgramSelection(binding.wrappedValue, equals: nil)
      binding.wrappedValue = nil
      #expect(
        content.appletData.selectedProgram(
          in: content.stateService.workspaceDefinition, for: content.stateService.localStateURL)
          == nil)
      expectProgramSelection(data.state(for: url).selectedProgramInternalID, equals: 22)
    }

    @Test("LUB-1049: Sidebar selection starts empty and remains Window local")
    func sidebarSelectionStartsEmptyAndStaysWindowLocal() throws {
      _ = NSApplication.shared
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      let other = WorkspaceDocument(definition: .init(), preferences: .init())
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

    @Test("LUB-1049: Physical assignments change only on explicit valid selection")
    func physicalAssignmentsAreDisplayOnlyUntilAnExplicitValidCommit() throws {
      let suite = "WorkspaceSelectionTests." + UUID().uuidString
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let data = WorkspaceAppletData(userDefaults: defaults)
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents = [
          WorkspaceResourceFactory.makeVFXSource(id: 101, name: "Camera"),
          WorkspaceResourceFactory.makeVFXSource(id: 102, name: "Other Camera"),
        ]
      }
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
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents.removeAll()
      }
      #expect(throws: WorkspaceSelectionError.self) { try field.applySelection(nil) }
    }

    @Test("LUB-1049: SwiftUI toolbar pane toggles stay Window local")
    func toolbarActionsStayWithinTheirWindow() async throws {
      let first = makeWorkspaceTestWindow()
      let second = makeWorkspaceTestWindow()
      defer {
        first.close()
        second.close()
      }
      first.orderFront(nil)
      await settleWorkspaceToolbar(first)
      let preview = first.contentPane.pairedPreview
      for id in ["workspace.toggleSidebar", "workspace.toggleInspector"] {
        let item = try #require(first.toolbar?.items.first { $0.itemIdentifier.rawValue == id })
        try performWorkspaceToolbarAction(item)
        await settleWorkspaceToolbar(first)
        if id == "workspace.toggleSidebar" {
          #expect(!first.stateService.isSidebarVisible)
          #expect(second.stateService.isSidebarVisible)
        } else {
          #expect(!first.stateService.isInspectorVisible)
          #expect(second.stateService.isInspectorVisible)
        }
        try performWorkspaceToolbarAction(item)
        await settleWorkspaceToolbar(first)
      }
      #expect(first.contentPane.pairedPreview === preview)
    }

    @Test(
      "LUB-1049: Collapsing a side pane preserves its draft and task results",
      arguments: [true, false])
    func collapsingSidePaneRetainsSubtree(isSidebar: Bool) async throws {
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      let probe = InspectorDraftProbe()
      let host = NSHostingController(
        rootView: WorkspaceLayout(
          stateService: state,
          sidebar: isSidebar ? AnyView(InspectorDraftView(probe: probe)) : AnyView(Text("Sidebar")),
          content: Text("Content"),
          inspector: isSidebar
            ? AnyView(Text("Inspector")) : AnyView(InspectorDraftView(probe: probe))))
      let window = NSWindow(contentViewController: host)
      window.isReleasedWhenClosed = false
      window.setContentSize(.init(width: 1062, height: 700))
      window.orderFront(nil)
      defer { window.close() }
      await settleWorkspaceToolbar(window)
      let draft = try #require(probe.draft)
      draft.wrappedValue = "-"
      await settleWorkspaceToolbar(window)
      if isSidebar { state.isSidebarVisible = false } else { state.isInspectorVisible = false }
      await settleWorkspaceToolbar(window)
      if isSidebar { state.isSidebarVisible = true } else { state.isInspectorVisible = true }
      await settleWorkspaceToolbar(window)
      #expect(probe.draft?.wrappedValue == "-")
      #expect(probe.instances.count == 1)
      #expect(probe.taskRuns == 1)
    }

    @MainActor
    private final class InspectorDraftProbe {
      var draft: Binding<String>?
      var instances: [UUID] = []
      var taskRuns = 0
    }

    @Test("LUB-1049: Collapsing the sidebar preserves its List scroll position")
    func collapsingSidebarRetainsScrollPosition() async throws {
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      let host = NSHostingController(
        rootView: WorkspaceLayout(
          stateService: state,
          sidebar: List(0..<100, id: \.self) { Text("Resource \($0)") },
          content: Text("Content"), inspector: Text("Inspector")))
      let window = NSWindow(contentViewController: host)
      window.isReleasedWhenClosed = false
      window.setContentSize(.init(width: 1062, height: 700))
      window.orderFront(nil)
      defer { window.close() }
      await settleWorkspaceToolbar(window)
      func scrollView(in view: NSView) -> NSScrollView? {
        (view as? NSScrollView) ?? view.subviews.lazy.compactMap { scrollView(in: $0) }.first
      }
      let scroll = try #require(scrollView(in: host.view))
      scroll.contentView.scroll(to: .init(x: 0, y: 400))
      scroll.reflectScrolledClipView(scroll.contentView)
      await settleWorkspaceToolbar(window)
      let offset = scroll.contentView.bounds.origin.y
      #expect(offset > 0)
      state.isSidebarVisible = false
      await settleWorkspaceToolbar(window)
      state.isSidebarVisible = true
      await settleWorkspaceToolbar(window)
      #expect(scrollView(in: host.view) === scroll)
      #expect(abs(scroll.contentView.bounds.origin.y - offset) <= 1)
    }

    private struct InspectorDraftView: View {
      let probe: InspectorDraftProbe
      @State private var draft = "0"
      @State private var instance = UUID()

      var body: some View {
        TextField("Numeric draft", text: $draft)
          .onAppear {
            probe.draft = $draft
            probe.instances.append(instance)
          }
          .task { probe.taskRuns += 1 }
      }
    }

    @Test("LUB-1049: Hidden side panes lower the SwiftUI minimum width")
    func minimumWidthFollowsVisiblePanes() async {
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      let host = NSHostingView(
        rootView: WorkspaceLayout(
          stateService: state,
          sidebar: Text("Sidebar"), content: Text("Content"), inspector: Text("Inspector")))
      for (sidebar, inspector, expected): (Bool, Bool, CGFloat) in [
        (true, true, 922), (false, true, 721), (true, false, 681), (false, false, 480),
      ] {
        state.isSidebarVisible = sidebar
        state.isInspectorVisible = inspector
        await drainWorkspaceTestTasks()
        #expect(state.minimumWindowWidth == expected)
        #expect(abs(host.fittingSize.width - expected) <= 1)
      }
    }

    @Test("LUB-1066: An unsaved Workspace disables output without disabling editing")
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
      document.stateService.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.displayName = "Still editable"
      }
      #expect(document.stateService.workspaceDefinition.displayName == "Still editable")
      #expect(document.fileURL == nil)
    }

    struct OutputControls: Sendable, Codable {
      let state: RecordingStateInput
      let stopEnabled: Bool
      let toggleEnabled: Bool
      let title: String
    }

    @Test(
      "LUB-1066: Output state determines toolbar availability",
      arguments: [
        OutputControls(
          state: .idle, stopEnabled: false, toggleEnabled: true, title: "Start Output"),
        OutputControls(
          state: .starting, stopEnabled: true, toggleEnabled: false, title: "Start Output"),
        OutputControls(
          state: .recording, stopEnabled: true, toggleEnabled: true, title: "Pause Output"),
        OutputControls(
          state: .pausing, stopEnabled: false, toggleEnabled: false, title: "Start Output"),
        OutputControls(
          state: .paused, stopEnabled: true, toggleEnabled: true, title: "Start Output"),
        OutputControls(
          state: .stopping, stopEnabled: false, toggleEnabled: false, title: "Start Output"),
        OutputControls(
          state: .failed, stopEnabled: false, toggleEnabled: true, title: "Start Output"),
      ])
    func outputControlAvailability(_ data: OutputControls) async throws {
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      state.recordingState = data.state.value
      let window = makeWorkspaceTestWindow(stateService: state, dispatcher: ToolbarDispatcher())
      defer { window.close() }
      await settleWorkspaceToolbar(window)
      let items = try #require(window.toolbar).items
      let stop = try #require(items.first { $0.itemIdentifier.rawValue == "workspace.stopOutput" })
      let toggle = try #require(
        items.first { $0.itemIdentifier.rawValue == "workspace.startPauseOutput" })
      #expect(window.validateToolbarItem(stop) == data.stopEnabled)
      #expect(window.validateToolbarItem(toggle) == data.toggleEnabled)
      #expect(toggle.menuFormRepresentation?.title == data.title)
    }

    struct OutputAction: Sendable, Codable {
      let state: RecordingStateInput
      let item: String
      let expected: [String]
    }

    @Test(
      "LUB-1066: Toolbar actions reach only their owning runtime",
      arguments: [
        OutputAction(state: .idle, item: "workspace.startPauseOutput", expected: ["start"]),
        OutputAction(state: .recording, item: "workspace.startPauseOutput", expected: ["pause"]),
        OutputAction(state: .paused, item: "workspace.stopOutput", expected: ["stop"]),
        OutputAction(state: .pausing, item: "workspace.startPauseOutput", expected: []),
      ])
    func outputAction(_ data: OutputAction) async throws {
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      state.recordingState = data.state.value
      let dispatcher = ToolbarDispatcher()
      let other = ToolbarDispatcher()
      let first = makeWorkspaceTestWindow(stateService: state, dispatcher: dispatcher)
      let second = makeWorkspaceTestWindow(dispatcher: other)
      defer {
        first.close()
        second.close()
      }
      await settleWorkspaceToolbar(first)
      let item = try #require(
        first.toolbar?.items.first { $0.itemIdentifier.rawValue == data.item })
      try performWorkspaceToolbarAction(item)
      await drainWorkspaceTestTasks()
      #expect(dispatcher.actions == data.expected)
      #expect(other.actions.isEmpty)
    }

    @Test("LUB-1066: Toolbar start failure remains observable")
    func toolbarStartFailureIsObservable() async throws {
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      let dispatcher = ToolbarDispatcher()
      dispatcher.failStart = true
      let window = makeWorkspaceTestWindow(stateService: state, dispatcher: dispatcher)
      defer { window.close() }
      await settleWorkspaceToolbar(window)
      let item = try #require(
        window.toolbar?.items.first { $0.itemIdentifier.rawValue == "workspace.startPauseOutput" })
      try performWorkspaceToolbarAction(item)
      await drainWorkspaceTestTasks()
      #expect(state.outputFailureMessage != nil)
    }

    struct ScreenshotState: Sendable, Codable {
      let outputActive: Bool
      let localRecording: Bool
    }

    @Test(
      "LUB-1046: Screenshot action is independent of output mode",
      arguments: [
        ScreenshotState(outputActive: false, localRecording: false),
        ScreenshotState(outputActive: true, localRecording: false),
        ScreenshotState(outputActive: true, localRecording: true),
      ])
    func screenshotToolbarAction(_ data: ScreenshotState) async throws {
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      state.isOutputActive = data.outputActive
      state.isLocalRecording = data.localRecording
      let dispatcher = ToolbarDispatcher()
      let window = makeWorkspaceTestWindow(stateService: state, dispatcher: dispatcher)
      defer { window.close() }
      await settleWorkspaceToolbar(window)
      let item = try #require(
        window.toolbar?.items.first { $0.itemIdentifier.rawValue == "workspace.captureScreenshots" }
      )
      #expect(item.isEnabled)
      try performWorkspaceToolbarAction(item)
      await drainWorkspaceTestTasks()
      #expect(dispatcher.actions == ["screenshot"])
    }

    @Test("LUB-1052: Program selection updates only the owning Window runtimes")
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
      configureCanvasProfiles(in: first)
      let firstWindow = attachCoordinator(to: first, appletData: data)
      firstWindow.adoptDocumentURL(URL(fileURLWithPath: "/tmp/First-\(UUID()).ldtxworkspace"))
      let a = try firstWindow.windowRuntime.addProgram(displayName: "First")
      let b = try firstWindow.windowRuntime.addProgram(displayName: "Second")
      copyProgramState(from: first, to: second)
      let secondWindow = attachCoordinator(to: second, appletData: data)
      secondWindow.adoptDocumentURL(URL(fileURLWithPath: "/tmp/Second-\(UUID()).ldtxworkspace"))
      let savedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: savedRoot) }
      try await saveDocumentPair(first, second, under: savedRoot)
      _ = await (try secondWindow.selectProgram(internalID: a)).value
      let landscape = try #require(firstWindow.windowRuntime.landscapeRuntime)
      let portrait = try #require(firstWindow.windowRuntime.portraitRuntime)
      let definition = first.stateService.workspaceDefinition
      first.stateService.inspectorSelector = .init(kind: .workspacePrograms)
      _ = await (try firstWindow.selectProgram(internalID: b)).value
      #expect(firstWindow.windowRuntime.landscapeRuntime === landscape)
      #expect(firstWindow.windowRuntime.portraitRuntime === portrait)
      expectProgramSelection(
        data.state(for: first.stateService.localStateURL!).selectedProgramInternalID, equals: b)
      expectProgramSelection(
        data.state(for: second.stateService.localStateURL!).selectedProgramInternalID, equals: a)
      // Content is now the live AppKit controller connected to this document.
      expectProgramSelection(
        data.selectedProgram(
          in: first.stateService.workspaceDefinition, for: first.stateService.localStateURL)?
          .internalID, equals: b)
      #expect(first.stateService.inspectorSelector == .init(kind: .workspacePrograms))
      let inspector = WorkspaceProgramsInspector(
        stateService: first.stateService, appletData: data,
        runtimeActions: { firstWindow })
      #expect(inspector.canSelectProgram)
      expectProgramSelection(inspector.programSelection.wrappedValue, equals: b)
      #expect(second.stateService.inspectorSelector == nil)
      #expect(first.stateService.workspaceDefinition == definition)
      #expect(throws: (any Error).self) { try firstWindow.selectProgram(internalID: Int64.max) }
      _ = await (try firstWindow.selectProgram(internalID: a)).value
      expectProgramSelection(
        data.state(for: first.stateService.localStateURL!).selectedProgramInternalID, equals: a)
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("Selection.ldtxworkspace")
      try await saveWorkspaceDocument(first, to: url)
      _ = await (try firstWindow.selectProgram(internalID: b)).value
      await firstWindow.shutdown()
      first.close()
      let reopened = try await loadWorkspaceDocument(at: url)
      defer { reopened.close() }
      let reopenedWindow = attachCoordinator(to: reopened, appletData: data)
      // Opening an existing file supplies its URL without moving transient window state.
      reopened.stateService.localStateURL = nil
      reopenedWindow.adoptDocumentURL(url)
      let reopenedInspector = WorkspaceProgramsInspector(
        stateService: reopened.stateService, appletData: data,
        runtimeActions: { reopenedWindow })
      expectProgramSelection(data.state(for: url).selectedProgramInternalID, equals: b)
      #expect(reopenedInspector.canSelectProgram)
      expectProgramSelection(reopenedInspector.programSelection.wrappedValue, equals: b)
      expectProgramSelection(
        data.selectedProgram(
          in: reopened.stateService.workspaceDefinition, for: reopened.stateService.localStateURL)?
          .internalID, equals: b)
      #expect(reopened.stateService.inspectorSelector == nil)
      await reopenedWindow.shutdown()
      await secondWindow.shutdown()
    }

    @Test(
      "LUB-1049: Shared device assignments update open Windows and stop after shutdown"
    )
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
      configureCanvasProfiles(in: first)
      let firstWindow = attachCoordinator(to: first, appletData: data)
      let input = try firstWindow.windowRuntime.addVFXSource(displayName: "Camera")
      firstWindow.adoptDocumentURL(URL(fileURLWithPath: "/tmp/First-\(UUID()).ldtxworkspace"))
      let program = try firstWindow.windowRuntime.addProgram(displayName: "Main")
      try firstWindow.windowRuntime.setVideoLayerOrder(
        [input], forProgramInternalID: program, target: .landscape)
      data.updateState(for: first.stateService.localStateURL!) {
        $0.selectedProgramInternalID = program
      }
      copyProgramState(from: first, to: second)
      let secondWindow = attachCoordinator(to: second, appletData: data)
      secondWindow.adoptDocumentURL(URL(fileURLWithPath: "/tmp/Second-\(UUID()).ldtxworkspace"))
      data.updateState(for: second.stateService.localStateURL!) {
        $0.selectedProgramInternalID = program
      }
      let savedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: savedRoot) }
      try await saveDocumentPair(first, second, under: savedRoot)
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

    @Test("LUB-1049: Dock badges follow AppDelegate's registered coordinators")
    func dockBadgeFollowsRegisteredControllers() async {
      let dockTile = NSApplication.shared.dockTile
      let originalBadge = dockTile.badgeLabel
      defer { dockTile.badgeLabel = originalBadge }
      let appDelegate = AppDelegate()
      let first = WorkspaceDocument()
      let second = WorkspaceDocument()
      let firstCoordinator = appDelegate.workspaceCoordinator(for: first)
      let secondCoordinator = appDelegate.workspaceCoordinator(for: second)
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
      await drainWorkspaceTestTasks()
      #expect(dockTile.badgeLabel == "REC")
      await firstCoordinator.shutdown()
      #expect(!first.isClosed)
      #expect(dockTile.badgeLabel == "REC")
      // This test projects output status without constructing live sessions.
      // Project Stop completion before asking either Workspace to close.
      first.stateService.isOutputActive = false
      await firstCoordinator.shutdown()
      #expect(dockTile.badgeLabel == "REC")
      second.stateService.isOutputActive = false
      await secondCoordinator.shutdown()
      #expect(dockTile.badgeLabel == nil)
    }

    @Test(
      "LUB-1050: Sidebar additions affect their own Document and persist only on Save")
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
      guard
        case .ocrVision(let vision) = reopened.stateService.workspaceDefinition.visions.first?
          .vision
      else {
        Issue.record("Missing OCR")
        return
      }
      #expect(vision.videoComponentInternalID == inputID)
    }

    @Test("LUB-1049: Sidebar Preview uses its provided state")
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
      "LUB-1050: Sidebar additions require a live Document",
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

    private func configureCanvasProfiles(in document: WorkspaceDocument) {
      document.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.canvasConfiguration = .with {
          $0.landscapeProfileID = "sdr-landscape-1080p60"
          $0.portraitProfileID = "sdr-portrait-1080p60"
        }
      }
    }

    private func copyProgramState(from first: WorkspaceDocument, to second: WorkspaceDocument) {
      second.editWorkspace(undoManager: nil) { workspace in
        workspace.definition = first.workspaceDefinition
      }
      second.editWorkspace(undoManager: nil) { workspace in
        workspace.preferences = first.workspacePreferences
      }
    }

    private func attachCoordinator(
      to document: WorkspaceDocument, appletData: WorkspaceAppletData
    ) -> WorkspaceAppletCoordinator {
      let coordinator = WorkspaceAppletCoordinator(
        stateService: document.stateService,
        persistenceCoordinator: document.persistenceCoordinator, appletData: appletData,
        document: document)
      document.addWindowController(coordinator)
      return coordinator
    }

    private func saveDocumentPair(
      _ first: WorkspaceDocument, _ second: WorkspaceDocument, under root: URL
    ) async throws {
      try await saveWorkspaceDocument(first, to: root.appendingPathComponent("First.ldtxworkspace"))
      try await saveWorkspaceDocument(
        second, to: root.appendingPathComponent("Second.ldtxworkspace"))
    }

    private func expectProgramSelection(
      _ actual: Int64?, equals expected: Int64?,
      sourceLocation: SourceLocation = #_sourceLocation()
    ) {
      #expect(actual == expected, sourceLocation: sourceLocation)
    }
  }
}
