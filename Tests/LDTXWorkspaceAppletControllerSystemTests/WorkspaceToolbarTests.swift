// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXDeviceRegistry
import LDTXProtos
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletInterface
@testable import LDTXWorkspaceAppletUI
import Observation
import SwiftUI
import Testing

@Suite(.serialized)
@MainActor
struct WorkspaceToolbarSystemTestSuite {
  @Test func swiftUIProgramRadiosLayOutVertically() {
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

  @Test func emptyProgramSelectorHasVisibleContent() {
    _ = NSApplication.shared
    let empty = NSHostingView(
      rootView: WorkspaceProgramSelector(programs: [], selection: .constant(nil)))
    #expect(empty.fittingSize.width > 0)
    #expect(empty.fittingSize.height > 0)
    #expect(empty.fittingSize.height <= 40)
  }

  @Test func programPickerSelectionResolvesDefinitionWithoutRewritingSavedIDs() throws {
    _ = NSApplication.shared
    let suite = "ProgramPicker." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let data = WorkspaceAppletData(userDefaults: defaults)
    let url = URL(fileURLWithPath: "/tmp/ProgramPicker-\(UUID()).ldtxworkspace")
    let state = WorkspaceUIState(definition: .init(), preferences: .init())
    state.localStateURL = url
    let window = makeWindow(uiState: state, appletData: data)
    defer { window.close() }
    let content = window.contentPane
    let inspector = WorkspaceProgramsInspector(uiState: state, appletData: data)
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
    #expect(content.selectedProgram?.internalID == 11)
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
    #expect(!content.showsProgramPreview)
    #expect(data.state(for: url).selectedProgramInternalID == 22)
  }

  @Test func sidebarSelectionStartsEmptyAndStaysWindowLocal() throws {
    _ = NSApplication.shared
    let state = WorkspaceUIState(definition: .init(), preferences: .init())
    let other = WorkspaceUIState(definition: .init(), preferences: .init())
    let window = makeWindow(uiState: state)
    let second = makeWindow(uiState: other)
    defer {
      window.close()
      second.close()
    }
    #expect(state.inspectorSelector == nil)
    state.inspectorSelector = .init(kind: .workspacePrograms)
    #expect(state.inspectorSelector != nil)
    #expect(other.inspectorSelector == nil)
  }

  @Test func physicalAssignmentsAreDisplayOnlyUntilAnExplicitValidCommit() throws {
    let suite = "WorkspaceSelectionTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let data = WorkspaceAppletData(userDefaults: defaults)
    let state = WorkspaceUIState(definition: .init(), preferences: .init())
    state.definition.inputDevices = [
      WorkspaceResourceFactory.makeVideoInput(id: 101, name: "Camera"),
      WorkspaceResourceFactory.makeVideoInput(id: 102, name: "Other Camera"),
    ]
    let unavailable = WorkspacePhysicalDeviceID.avCaptureDevice(uniqueID: "missing-camera")
    data.setPhysicalDeviceID(unavailable, for: 101)
    data.setPhysicalDeviceID(unavailable, for: 102)
    let field = WorkspacePhysicalDeviceField(
      title: "Camera", internalID: 101, isAudio: false, uiState: state,
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
    state.definition.inputDevices.removeAll()
    #expect(throws: WorkspaceSelectionError.self) { try field.applySelection(nil) }
  }

  @Test func contentOwnsLayerEditingForBothCanvases() {
    _ = NSApplication.shared
    let state = WorkspaceUIState(definition: .init(), preferences: .init())
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 100
    program.displayName = "Main"
    state.definition.programs = [program]
    state.definition.videoComponents = [10, 20, 30].map {
      WorkspaceResourceFactory.makeSolidColor(id: UInt64($0), name: "Color \($0)")
    }
    let other = WorkspaceUIState(definition: state.definition, preferences: .init())
    let first = makeWindow(uiState: state)
    let second = makeWindow(uiState: other)
    defer {
      first.close()
      second.close()
    }
    let content = first.contentPane
    for role in ProgramCanvasRole.allCases {
      content.addVideoLayer(10, to: state.definition.programs[0], role: role)
      content.addVideoLayer(20, to: state.definition.programs[0], role: role)
      content.moveVideoLayer(in: state.definition.programs[0], role: role, from: 1, offset: -1)
      let ids =
        role == .landscape
        ? state.definition.programs[0].landscapeVideoLayerInternalIds
        : state.definition.programs[0].portraitVideoLayerInternalIds
      #expect(ids == [20, 10])
      content.removeVideoLayer(in: state.definition.programs[0], role: role, at: 0)
      let before = state.definition
      for value in [WorkspaceRecordingState.starting, .recording, .pausing, .stopping] {
        state.isOutputActive = value.isOutputActive
        content.addVideoLayer(30, to: state.definition.programs[0], role: role)
        content.moveVideoLayer(in: state.definition.programs[0], role: role, from: 0, offset: 1)
        content.removeVideoLayer(in: state.definition.programs[0], role: role, at: 0)
        #expect(state.definition == before)
      }
      state.isOutputActive = false
    }
    #expect(state.definition.programs[0].landscapeVideoLayerInternalIds == [10])
    #expect(state.definition.programs[0].portraitVideoLayerInternalIds == [10])
    #expect(other.definition.programs[0].landscapeVideoLayerInternalIds.isEmpty)
    #expect(other.definition.programs[0].portraitVideoLayerInternalIds.isEmpty)
    #expect(state.inspectorSelector == nil)
    #expect(other.inspectorSelector == nil)
    #expect(WorkspaceInspectorKind(rawValue: 1) == nil)
    #expect(WorkspaceInspectorKind.workspaceCanvas.rawValue == 2)
    #expect(WorkspaceInspectorKind.ocrVision.rawValue == 13)
  }

  @Test func toolbarActionsRestoreWidthsAndStayWithinTheirWindow() throws {
    _ = NSApplication.shared
    let first = makeWindow()
    let second = makeWindow()
    defer {
      first.close()
      second.close()
    }
    let toolbar = try #require(first.toolbar)
    #expect(toolbar.identifier == "WorkspaceV4Toolbar.AppKit.v1")
    #expect(first.toolbarStyle == .unified)
    #expect(first.titleVisibility == .visible)
    #expect(toolbar.displayMode == .iconOnly)
    #expect(first.styleMask.contains(.fullSizeContentView))
    #expect(
      toolbar.items.map(\.itemIdentifier) == [
        .init("workspace.sidebar"), .sidebarTrackingSeparator,
        .init("workspace.stopOutput"), .init("workspace.toggleOutput"),
        .flexibleSpace,
        .inspectorTrackingSeparator, .flexibleSpace, .init("workspace.inspector"),
      ])
    #expect(first.contentLayoutRect.size == NSSize(width: 1062, height: 700))
    let split = try #require(first.contentViewController as? PaneSplitViewController)
    let other = try #require(second.contentViewController as? PaneSplitViewController)
    split.view.layoutSubtreeIfNeeded()
    for (pane, expectedWidth) in zip(split.splitView.arrangedSubviews, [240.0, 480.0, 340.0]) {
      #expect(abs(pane.frame.width - expectedWidth) <= 1)
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

  @Test func outputButtonsReflectStateAndDispatchToTheirWindow() async throws {
    _ = NSApplication.shared
    let state = WorkspaceUIState(definition: .init(), preferences: .init())
    let dispatcher = ToolbarDispatcher()
    let otherDispatcher = ToolbarDispatcher()
    let first = makeWindow(uiState: state, dispatcher: dispatcher)
    let second = makeWindow(dispatcher: otherDispatcher)
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
    await drainTasks()
    #expect(dispatcher.actions == ["start"])
    state.recordingState = .recording
    #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
    await drainTasks()
    #expect(dispatcher.actions == ["start", "pause"])
    state.recordingState = .paused
    #expect(NSApp.sendAction(try #require(stop.action), to: stop.target, from: stop))
    await drainTasks()
    #expect(dispatcher.actions == ["start", "pause", "stop"])
    state.recordingState = .pausing
    #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
    await drainTasks()
    #expect(dispatcher.actions == ["start", "pause", "stop"])
    #expect(otherDispatcher.actions.isEmpty)
    state.recordingState = .idle
    dispatcher.failStart = true
    #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
    await drainTasks()
    #expect(state.outputFailureMessage != nil)
  }

  @Test func controllerSharesOutputRuntimesWithContent() async throws {
    _ = NSApplication.shared
    let document = WorkspaceDocument()
    let controller = WorkspaceWindowController(
      uiState: document.uiState, persistenceCoordinator: document.persistenceCoordinator,
      appletData: WorkspaceAppletData(), documentReference: DocumentReference(document))
    let window = try #require(controller.window as? WorkspaceWindow)
    #expect(
      controller.windowRuntime.runtime(for: .landscape) === window.contentPane.landscapeRuntime)
    #expect(controller.windowRuntime.runtime(for: .portrait) === window.contentPane.portraitRuntime)
    await controller.shutdown()
    window.close()
    document.close()
  }

  @Test func contentPreviewUsesInjectedRuntimesAndTracksItsOwnProgram() {
    _ = NSApplication.shared
    let state = WorkspaceUIState(definition: .init(), preferences: .init())
    let otherState = WorkspaceUIState(definition: .init(), preferences: .init())
    let first = makeWindow(uiState: state)
    let second = makeWindow(uiState: otherState)
    defer {
      first.close()
      second.close()
    }
    let firstLandscape = first.contentPane.landscapeRuntime
    let firstPortrait = first.contentPane.portraitRuntime
    #expect(firstLandscape !== second.contentPane.landscapeRuntime)
    #expect(firstPortrait !== second.contentPane.portraitRuntime)
    #expect(!first.contentPane.showsProgramPreview)
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 42
    program.displayName = "Preview"
    state.definition.programs = [program]
    #expect(first.contentPane.showsProgramPreview)
    #expect(!second.contentPane.showsProgramPreview)
    for value in [WorkspaceRecordingState.idle, .recording, .paused] {
      state.recordingState = value
      #expect(first.contentPane.showsProgramPreview)
      #expect(first.contentPane.landscapeRuntime === firstLandscape)
      #expect(first.contentPane.portraitRuntime === firstPortrait)
    }
    state.definition.programs = []
    #expect(!first.contentPane.showsProgramPreview)
  }

  private func drainTasks() async {
    // The action creates a main-actor task; yield until it has run.
    for _ in 0..<10 { await Task.yield() }
  }

  private func makeWindow(
    uiState: WorkspaceUIState? = nil,
    dispatcher: (any WorkspaceDispatcherProtocol)? = nil,
    appletData: WorkspaceAppletData? = nil
  ) -> WorkspaceWindow {
    let document = WorkspaceDocument()
    return WorkspaceWindow(
      url: URL(fileURLWithPath: "/tmp/Toolbar-\(UUID()).ldtxworkspace"),
      deviceRegistry: DeviceRegistryService(), appletData: appletData ?? WorkspaceAppletData(),
      dispatcher: dispatcher ?? WorkspaceDispatcher(), uiState: uiState ?? document.uiState,
      documentReference: DocumentReference(document),
      landscapeRuntime: ProgramRuntime(
        captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
        lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry()),
      portraitRuntime: ProgramRuntime(
        captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
        lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry()))
  }
}

@MainActor
@Observable
private final class ToolbarDispatcher: WorkspaceDispatcherProtocol {
  var actions: [String] = []
  var failStart = false
  func startOutput() async throws {
    actions.append("start")
    if failStart { throw CocoaError(.fileReadNoSuchFile) }
  }
  func pauseOutput() async { actions.append("pause") }
  func stopOutput() async { actions.append("stop") }
  func synchronizeVision() {}
  func synchronizeAudioMonitor() {}
  func synchronizeCaptureInputs(
    availableCameraIDs: Set<String>, completionHandler: @escaping @Sendable (Set<String>) -> Void
  ) { completionHandler([]) }
  func selectProgram(internalID: UInt64) throws {}
  func updateProgramRuntimes() {}
  func updateMixPreferences() {}
  func captureScreenshots() throws -> [URL] { [] }
  func openScreenshotsDirectory() {}
}
