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
    #expect(content.selectedProgram == nil)
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
    state.definition.videoComponents = [
      WorkspaceResourceFactory.makeVFXSource(id: 101, name: "Camera"),
      WorkspaceResourceFactory.makeVFXSource(id: 102, name: "Other Camera"),
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
    state.definition.videoComponents.removeAll()
    #expect(throws: WorkspaceSelectionError.self) { try field.applySelection(nil) }
  }

  @Test func videoLayersEditorEditsBothCanvases() throws {
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
    for target in [WorkspaceCanvasTarget.landscape, .portrait] {
      let candidates = VideoLayersManagementSheet.options(in: state.definition)
      let content = first.contentPane
      try content.commitVideoLayerMembership(
        [10, 20, 30], expectedIDs: [], expectedCandidates: candidates,
        programInternalID: 100, target: target)
      try content.commitLayerOrder([30, 10, 20], programID: 100, target: target)
      #expect(state.definition.programs[0][keyPath: target.layerIDs] == [30, 10, 20])
      #expect(throws: WorkspaceSelectionError.self) {
        try content.commitLayerOrder([10], programID: 100, target: target)
      }
      try content.commitVideoLayerMembership(
        [10, 20], expectedIDs: [30, 10, 20], expectedCandidates: candidates,
        programInternalID: 100, target: target)
      var preference = try content.preferences(for: 100, target: target)
      preference.audioMasterVolumeDecibelTenths = -80
      preference.videoLayerHidden[10] = true
      try content.commitPreferences(preference, programID: 100, target: target)
      #expect(state.preferences[keyPath: target.preferences][100]?.videoLayerHidden[10] == true)
      #expect(
        state.preferences[keyPath: target.preferences][100]?.audioMasterVolumeDecibelTenths == -80)
      for value in [WorkspaceRecordingState.starting, .recording, .pausing, .stopping] {
        state.isOutputActive = value.isOutputActive
        #expect(throws: WorkspaceSelectionError.self) {
          try content.commitVideoLayerMembership(
            [10], expectedIDs: [10, 20], expectedCandidates: candidates,
            programInternalID: 100, target: target)
        }
        try content.commitLayerOrder([20, 10], programID: 100, target: target)
        try content.commitLayerOrder([10, 20], programID: 100, target: target)
      }
      state.isOutputActive = false
      try content.commitVideoLayerMembership(
        [10], expectedIDs: [10, 20], expectedCandidates: candidates,
        programInternalID: 100, target: target)
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

  @Test func contentTabsAndAudioTargetAreIndependentAndWindowLocal() {
    let first = makeWindow()
    let second = makeWindow()
    defer {
      first.close()
      second.close()
    }
    #expect(first.contentPane.videoTabs.tabViewItems.map(\.label) == ["Landscape", "Portrait"])
    #expect(first.contentPane.videoTabs.selectedTabViewItemIndex == 0)
    #expect(first.contentPane.audio.view.isDescendant(of: first.contentPane.view))
    first.contentPane.videoTabs.selectedTabViewItemIndex = 1
    #expect(first.contentPane.uiState.selectedAudioMix == .landscape)
    first.contentPane.uiState.selectedAudioMix = .portrait
    first.contentPane.refresh()
    #expect(first.contentPane.audio.targetSelector.selectedSegment == 1)
    first.contentPane.audio.targetSelector.selectedSegment = 0
    first.contentPane.audio.targetSelector.sendAction(
      first.contentPane.audio.targetSelector.action!,
      to: first.contentPane.audio.targetSelector.target)
    #expect(first.contentPane.uiState.selectedAudioMix == .landscape)
    #expect(first.contentPane.videoTabs.selectedTabViewItemIndex == 1)
    #expect(second.contentPane.videoTabs.selectedTabViewItemIndex == 0)
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
        .init("workspace.captureScreenshots"), .init("workspace.openScreenshotsFolder"),
        .flexibleSpace,
        .inspectorTrackingSeparator, .flexibleSpace, .init("workspace.inspector"),
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

  @Test func screenshotToolbarActionsRequireLocalRecording() throws {
    _ = NSApplication.shared
    let state = WorkspaceUIState(definition: .init(), preferences: .init())
    let dispatcher = ToolbarDispatcher()
    let window = makeWindow(uiState: state, dispatcher: dispatcher)
    defer { window.close() }
    for (id, expected) in [
      ("workspace.captureScreenshots", "screenshot"),
      ("workspace.openScreenshotsFolder", "screenshotsFolder"),
    ] {
      let item = try #require(window.toolbar?.items.first { $0.itemIdentifier.rawValue == id })
      let action = try #require(item.action)
      #expect(!window.validateToolbarItem(item))
      _ = NSApp.sendAction(action, to: item.target, from: item)
      #expect(dispatcher.actions.isEmpty)
      state.isOutputActive = true
      state.isLocalRecording = false
      #expect(!window.validateToolbarItem(item))
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

  @Test func controllerOwnsAndStopsPreviewRenderer() async throws {
    _ = NSApplication.shared
    let document = WorkspaceDocument()
    let controller = WorkspaceWindowController(
      uiState: document.uiState, persistenceCoordinator: document.persistenceCoordinator,
      appletData: WorkspaceAppletData(), documentReference: DocumentReference(document))
    let window = try #require(controller.window as? WorkspaceWindow)
    #expect(window.contentController.preview.metalView.delegate === controller.previewRenderer)
    #expect(
      controller.windowRuntime.landscapeRuntime
        !== controller.windowRuntime.portraitRuntime)
    await controller.shutdown()
    #expect(window.contentController.preview.metalView.delegate == nil)
    #expect(window.contentController.preview.metalView.isPaused)
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
    let firstPreview = first.contentController.preview
    let firstDelegate = firstPreview.metalView.delegate
    #expect(firstPreview !== second.contentController.preview)
    #expect(firstDelegate !== second.contentController.preview.metalView.delegate)
    #expect(first.contentPane.selectedProgram == nil)
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 42
    program.displayName = "Preview"
    state.definition.programs = [program]
    #expect(first.contentPane.selectedProgram != nil)
    #expect(second.contentPane.selectedProgram == nil)
    for value in [WorkspaceRecordingState.idle, .recording, .paused] {
      state.recordingState = value
      #expect(first.contentPane.selectedProgram != nil)
      #expect(first.contentController.preview === firstPreview)
      #expect(firstPreview.metalView.delegate === firstDelegate)
    }
    state.definition.programs = []
    #expect(first.contentPane.selectedProgram == nil)
  }

  @Test func appKitPreviewSelectionAndSplitPositionAreWindowLocal() throws {
    _ = NSApplication.shared
    let url = URL(fileURLWithPath: "/tmp/PreviewLayout-\(UUID()).ldtxworkspace")
    let defaults = try #require(UserDefaults(suiteName: "PreviewLayout-\(UUID())"))
    let data = WorkspaceAppletData(userDefaults: defaults)
    let state = WorkspaceUIState(definition: .init(), preferences: .init())
    var changes = 0
    state.documentContentsDidChange = { changes += 1 }
    let first = makeWindow(uiState: state, appletData: data, url: url)
    defer { first.close() }
    let pane = first.contentController
    #expect(!pane.splitView.isVertical)
    #expect(pane.preview.metalView.delegate != nil)
    first.orderFront(nil)
    pane.splitView.setPosition(150, ofDividerAt: 0)
    first.contentView?.layoutSubtreeIfNeeded()
    pane.preview.layout()
    let metalFrameInWindow = pane.preview.metalView.convert(pane.preview.metalView.bounds, to: nil)
    #expect(metalFrameInWindow.maxY <= first.contentLayoutRect.maxY + 0.5)
    pane.preview.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
    pane.preview.layout()
    let size = pane.preview.metalView.bounds.size
    pane.preview.selectCanvas(at: CGPoint(x: size.width - 20, y: size.height / 2))
    #expect(state.selectedAudioMix == .portrait)
    pane.preview.selectCanvas(at: CGPoint(x: 20, y: size.height / 2))
    #expect(state.selectedAudioMix == .landscape)
    pane.splitView.setPosition(220, ofDividerAt: 0)
    pane.saveDividerPosition()
    let saved = try #require(data.state(for: url).contentPreviewHeightRatio)
    #expect(saved > 0 && saved < 1)
    first.setContentSize(NSSize(width: 1100, height: 800))
    first.contentView?.layoutSubtreeIfNeeded()
    #expect(data.state(for: url).contentPreviewHeightRatio == saved)
    let reopened = makeWindow(uiState: state, appletData: data, url: url)
    defer { reopened.close() }
    let split = reopened.contentController.splitView
    let ratio = Double(
      split.arrangedSubviews[0].frame.height / (split.bounds.height - split.dividerThickness))
    #expect(abs(ratio - saved) < 0.01)
    #expect(changes == 0)
    pane.preview.stop()
    #expect(pane.preview.metalView.delegate == nil)
    #expect(pane.preview.metalView.isPaused)
  }

  @Test func oldLocalStateDoesNotRequirePreviewHeight() throws {
    let encoded = try JSONEncoder().encode(WorkspaceLocalState())
    #expect(!String(decoding: encoded, as: UTF8.self).contains("contentPreviewHeightRatio"))
    #expect(
      try JSONDecoder().decode(WorkspaceLocalState.self, from: encoded).contentPreviewHeightRatio
        == nil)
  }

  private func drainTasks() async {
    // The action creates a main-actor task; yield until it has run.
    for _ in 0..<10 { await Task.yield() }
  }

  private func makeWindow(
    uiState: WorkspaceUIState? = nil,
    dispatcher: (any WorkspaceDispatcherProtocol)? = nil,
    appletData: WorkspaceAppletData? = nil,
    url: URL? = nil
  ) -> WorkspaceWindow {
    let document = WorkspaceDocument()
    return WorkspaceWindow(
      url: url ?? URL(fileURLWithPath: "/tmp/Toolbar-\(UUID()).ldtxworkspace"),
      deviceRegistry: DeviceRegistryService(), appletData: appletData ?? WorkspaceAppletData(),
      dispatcher: dispatcher ?? WorkspaceDispatcher(), uiState: uiState ?? document.uiState,
      documentReference: DocumentReference(document),
      previewRenderer: ProgramPairPreviewRenderer(
        landscapeRuntime: ProgramRuntime(
          captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
          lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry()),
        portraitRuntime: ProgramRuntime(
          captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
          lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry()),
        landscapeSize: CGSize(width: 16, height: 9), portraitSize: CGSize(width: 9, height: 16),
        prefersColor: true),
      audioPeakMeter: ProgramAudioPeakMeter())
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
  func captureScreenshots() throws -> [URL] {
    actions.append("screenshot")
    return []
  }
  func openScreenshotsDirectory() { actions.append("screenshotsFolder") }
}
