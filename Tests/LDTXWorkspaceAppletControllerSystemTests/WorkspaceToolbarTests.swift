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
  @Test func meterOwnsDrawingLifetimeAndEditorsReleaseWithoutStop() async throws {
    _ = NSApplication.shared
    let first = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    let second = NSWindow(
      contentRect: first.frame, styleMask: [.titled], backing: .buffered, defer: false)
    first.isReleasedWhenClosed = false
    second.isReleasedWhenClosed = false
    defer {
      first.close()
      second.close()
    }
    var meter: AudioPeakMeterMTKView? = AudioPeakMeterMTKView()
    weak var releasedMeter = meter
    #expect(try #require(meter).isPaused)
    first.contentView?.addSubview(try #require(meter))
    #expect(meter?.isPaused == (meter?.device == nil))
    first.close()
    #expect(meter?.isPaused == true)
    meter?.removeFromSuperview()
    second.contentView?.addSubview(try #require(meter))
    #expect(meter?.isPaused == (meter?.device == nil))
    meter?.removeFromSuperview()
    #expect(meter?.isPaused == true)
    meter = nil
    for _ in 0..<100 {
      if releasedMeter == nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(releasedMeter == nil)

    let service = WorkspaceStoreService(definition: .init(), preferences: .init())
    var audio: AudioMixEditor? = AudioMixEditor(storeService: service)
    var master: MasterVolumeEditor? = MasterVolumeEditor(storeService: service)
    var layers: VideoLayersEditor? = VideoLayersEditor(storeService: service, target: .landscape)
    weak var releasedAudio = audio
    weak var releasedMaster = master
    weak var releasedLayers = layers
    _ = audio?.view
    _ = master?.view
    _ = layers?.view
    audio = nil
    master = nil
    layers = nil
    #expect(releasedAudio == nil)
    #expect(releasedMaster == nil)
    #expect(releasedLayers == nil)
  }

  @Test func storeRejectsOperationsWithoutRuntime() async {
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

  @Test func editorsObserveStoreThroughAppKitLayout() async throws {
    _ = NSApplication.shared
    let service = WorkspaceStoreService(definition: .init(), preferences: .init())
    let content = AudioMixEditor(storeService: service)
    #expect(!content.isViewLoaded)
    service.outputFailureMessage = "Initial failure"
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = content
    window.orderFront(nil)
    defer { window.close() }
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(content.outputErrorLabel.stringValue == "Initial failure")
    service.outputFailureMessage = "Updated failure"
    for _ in 0..<50 {
      if content.outputErrorLabel.stringValue == "Updated failure" { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(content.outputErrorLabel.stringValue == "Updated failure")
  }

  @Test func masterEditorObservesAndEditsVolumesIndependently() async throws {
    _ = NSApplication.shared
    let service = WorkspaceStoreService(definition: .init(), preferences: .init())
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 100
    service.definition.programs = [program]
    let editor = MasterVolumeEditor(storeService: service)
    #expect(!editor.isViewLoaded)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = editor
    window.orderFront(nil)
    defer { window.close() }
    window.contentView?.layoutSubtreeIfNeeded()
    let field = editor.masterFields[0]
    field.stringValue = "-12.0"
    field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    field.commit()
    #expect(
      try service.preferences(for: 100, target: .landscape).audioMasterVolumeDecibels
        == Ldtx_Workspace_V4_Rational32.with {
          $0.numerator = -12
          $0.denominator = 1
        })
    #expect(service.selectedAudioMix == .landscape)
    service.updateAudio(target: .landscape) {
      $0.audioMasterVolumeDecibels = .with {
        $0.numerator = -6
        $0.denominator = 1
      }
    }
    for _ in 0..<50 {
      if field.stringValue == "-6" { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(field.stringValue == "-6")
  }

  @Test func audioMixEditsWorkspaceGainWithoutCanvasOrProgramSelection() throws {
    _ = NSApplication.shared
    let service = WorkspaceStoreService(definition: .init(), preferences: .init())
    service.definition.audioDevices = [
      WorkspaceResourceFactory.makeAudioInput(id: 10, name: "Input")
    ]
    service.selectedAudioMix = .portrait
    let editor = AudioMixEditor(storeService: service)
    func descendants(_ view: NSView) -> [NSView] {
      view.subviews.flatMap { [$0] + descendants($0) }
    }
    let views = descendants(editor.view)
    #expect(!views.contains { $0 is NSSegmentedControl })
    let gains = views.compactMap { $0 as? AudioChannelControlView }
    #expect(gains.count == 1)
    let gain = try #require(gains.first)
    let slider = try #require(descendants(gain).compactMap { $0 as? NSSlider }.first)
    #expect(slider.isEnabled)
    slider.doubleValue = -12
    slider.sendAction(try #require(slider.action), to: slider.target)
    #expect(
      service.preferences.audioChannelGainsDecibels[10]
        == Ldtx_Workspace_V4_Rational32.with {
          $0.numerator = -12
          $0.denominator = 1
        })
    #expect(!service.setAudioChannelGain(.nan, forAudioInputDeviceInternalID: 10))
    #expect(!service.setAudioChannelGain(-6, forAudioInputDeviceInternalID: 999))
    #expect(
      service.preferences.audioChannelGainsDecibels[10]
        == Ldtx_Workspace_V4_Rational32.with {
          $0.numerator = -12
          $0.denominator = 1
        })
    #expect(service.selectedAudioMix == .portrait)
  }

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
    let state = WorkspaceStoreService(definition: .init(), preferences: .init())
    state.localStateURL = url
    let window = makeWindow(storeService: state, appletData: data)
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

  @Test func sidebarSelectionStartsEmptyAndStaysWindowLocal() throws {
    _ = NSApplication.shared
    let state = WorkspaceStoreService(definition: .init(), preferences: .init())
    let other = WorkspaceStoreService(definition: .init(), preferences: .init())
    let window = makeWindow(storeService: state)
    let second = makeWindow(storeService: other)
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

  @Test func videoLayersEditorEditsBothCanvases() throws {
    _ = NSApplication.shared
    let state = WorkspaceStoreService(definition: .init(), preferences: .init())
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 100
    program.displayName = "Main"
    state.definition.programs = [program]
    state.definition.videoComponents = [10, 20, 30].map {
      WorkspaceResourceFactory.makeSolidColor(id: UInt64($0), name: "Color \($0)")
    }
    let other = WorkspaceStoreService(definition: state.definition, preferences: .init())
    let first = makeWindow(storeService: state)
    let second = makeWindow(storeService: other)
    defer {
      first.close()
      second.close()
    }
    for target in [WorkspaceCanvasTarget.landscape, .portrait] {
      let content = first.contentPane
      for id: UInt64 in [10, 20, 30] {
        try content.storeService.setVideoLayerIncluded(
          true, componentID: id, programID: 100, target: target)
      }
      try content.storeService.commitLayerOrder([30, 10, 20], programID: 100, target: target)
      #expect(state.definition.programs[0][keyPath: target.layerIDs] == [30, 10, 20])
      #expect(throws: WorkspaceSelectionError.self) {
        try content.storeService.commitLayerOrder([10], programID: 100, target: target)
      }
      try content.storeService.setVideoLayerIncluded(
        false, componentID: 30, programID: 100, target: target)
      var preference = try content.storeService.preferences(for: 100, target: target)
      preference.audioMasterVolumeDecibels = .with {
        $0.numerator = -8
        $0.denominator = 1
      }
      preference.videoLayerHidden[10] = true
      try content.storeService.commitPreferences(preference, programID: 100, target: target)
      #expect(state.preferences[keyPath: target.preferences][100]?.videoLayerHidden[10] == true)
      #expect(
        state.preferences[keyPath: target.preferences][100]?.audioMasterVolumeDecibels
          == Ldtx_Workspace_V4_Rational32.with {
            $0.numerator = -8
            $0.denominator = 1
          })
      for value in [WorkspaceRecordingState.starting, .recording, .pausing, .stopping] {
        state.isOutputActive = value.isOutputActive
        #expect(throws: WorkspaceSelectionError.self) {
          try content.storeService.setVideoLayerIncluded(
            false, componentID: 20, programID: 100, target: target)
        }
        try content.storeService.commitLayerOrder([20, 10], programID: 100, target: target)
        try content.storeService.commitLayerOrder([10, 20], programID: 100, target: target)
      }
      state.isOutputActive = false
      try content.storeService.setVideoLayerIncluded(
        false, componentID: 20, programID: 100, target: target)
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
    #expect(
      first.contentPane.testVideoTabs.tabViewItems.map(\.label) == [
        "Landscape Video Layers", "Portrait Video Layers",
      ])
    #expect(first.contentPane.testVideoTabs.selectedTabViewItemIndex == 0)
    #expect(
      first.contentPane.testAudioMixEditor.view.isDescendant(
        of: first.contentPane.view))
    first.contentPane.testVideoTabs.selectedTabViewItemIndex = 1
    #expect(first.contentPane.storeService.selectedAudioMix == .landscape)
    first.contentPane.storeService.selectedAudioMix = .portrait
    #expect(first.contentPane.storeService.selectedAudioMix == .portrait)
    #expect(first.contentPane.testVideoTabs.selectedTabViewItemIndex == 1)
    #expect(second.contentPane.testVideoTabs.selectedTabViewItemIndex == 0)
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
    let state = WorkspaceStoreService(definition: .init(), preferences: .init())
    let dispatcher = ToolbarDispatcher()
    let otherDispatcher = ToolbarDispatcher()
    let first = makeWindow(storeService: state, dispatcher: dispatcher)
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
    let state = WorkspaceStoreService(definition: .init(), preferences: .init())
    let dispatcher = ToolbarDispatcher()
    let window = makeWindow(storeService: state, dispatcher: dispatcher)
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
      storeService: document.storeService, persistenceCoordinator: document.persistenceCoordinator,
      appletData: WorkspaceAppletData(), documentReference: DocumentReference(document))
    let window = try #require(controller.window as? WorkspaceWindow)
    #expect(
      window.contentPane.testPairedPreview.metalView.delegate === controller.previewRenderer)
    #expect(
      controller.windowRuntime.landscapeRuntime
        !== controller.windowRuntime.portraitRuntime)
    await controller.shutdown()
    #expect(window.contentPane.testPairedPreview.metalView.delegate == nil)
    #expect(window.contentPane.testPairedPreview.metalView.isPaused)
    window.close()
    document.close()
  }

  @Test func contentPreviewUsesInjectedRuntimesAndTracksItsOwnProgram() {
    _ = NSApplication.shared
    let state = WorkspaceStoreService(definition: .init(), preferences: .init())
    let otherState = WorkspaceStoreService(definition: .init(), preferences: .init())
    let first = makeWindow(storeService: state)
    let second = makeWindow(storeService: otherState)
    defer {
      first.close()
      second.close()
    }
    let firstPreview = first.contentPane.testPairedPreview
    let firstDelegate = firstPreview.metalView.delegate
    #expect(firstPreview !== second.contentPane.testPairedPreview)
    #expect(firstDelegate !== second.contentPane.testPairedPreview.metalView.delegate)
    #expect(first.contentPane.storeService.selectedProgram == nil)
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 42
    program.displayName = "Preview"
    state.definition.programs = [program]
    #expect(first.contentPane.storeService.selectedProgram != nil)
    #expect(second.contentPane.storeService.selectedProgram == nil)
    for value in [WorkspaceRecordingState.idle, .recording, .paused] {
      state.recordingState = value
      #expect(first.contentPane.storeService.selectedProgram != nil)
      #expect(first.contentPane.testPairedPreview === firstPreview)
      #expect(firstPreview.metalView.delegate === firstDelegate)
    }
    state.definition.programs = []
    #expect(first.contentPane.storeService.selectedProgram == nil)
  }

  @Test func appKitPreviewSelectionAndSplitPositionAreWindowLocal() throws {
    _ = NSApplication.shared
    let url = URL(fileURLWithPath: "/tmp/PreviewLayout-\(UUID()).ldtxworkspace")
    let defaults = try #require(UserDefaults(suiteName: "PreviewLayout-\(UUID())"))
    let data = WorkspaceAppletData(userDefaults: defaults)
    let state = WorkspaceStoreService(definition: .init(), preferences: .init())
    var changes = 0
    state.documentContentsDidChange = { changes += 1 }
    let externalID = UUID().uuidString.lowercased()
    let first = makeWindow(storeService: state, appletData: data, url: url, externalID: externalID)
    defer { first.close() }
    let pane = first.contentPane
    #expect(!pane.testSplitView.isVertical)
    #expect(pane.testPairedPreview.metalView.delegate != nil)
    first.orderFront(nil)
    #expect(pane.testSplitView.arrangedSubviews[1] === pane.testEditorScrollView)
    #expect(pane.testEditorScrollView.hasVerticalScroller)
    pane.testSplitView.setPosition(pane.testSplitView.bounds.height - 80, ofDividerAt: 0)
    first.contentView?.layoutSubtreeIfNeeded()
    let editorDocument = try #require(pane.testEditorScrollView.documentView)
    #expect(editorDocument is NSStackView)
    #expect(editorDocument.isFlipped)
    #expect(editorDocument.frame.height > pane.testEditorScrollView.contentView.bounds.height)
    #expect(
      abs(editorDocument.frame.width - pane.testEditorScrollView.contentView.bounds.width) < 0.5)
    editorDocument.scroll(NSPoint(x: 0, y: editorDocument.frame.height))
    #expect(pane.testEditorScrollView.contentView.bounds.origin.y > 0)
    editorDocument.scroll(.zero)
    #expect(pane.testEditorScrollView.contentView.bounds.origin.y == 0)
    pane.testSplitView.setPosition(150, ofDividerAt: 0)
    first.contentView?.layoutSubtreeIfNeeded()
    pane.testPairedPreview.layout()
    let metalFrameInWindow = pane.testPairedPreview.metalView.convert(
      pane.testPairedPreview.metalView.bounds, to: nil)
    #expect(metalFrameInWindow.maxY <= first.contentLayoutRect.maxY + 0.5)
    pane.testPairedPreview.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
    pane.testPairedPreview.layout()
    let size = pane.testPairedPreview.metalView.bounds.size
    pane.testPairedPreview.selectCanvas(at: CGPoint(x: size.width - 20, y: size.height / 2))
    #expect(state.selectedAudioMix == .portrait)
    pane.testPairedPreview.selectCanvas(at: CGPoint(x: 20, y: size.height / 2))
    #expect(state.selectedAudioMix == .landscape)
    pane.testSplitView.setPosition(220, ofDividerAt: 0)
    first.contentView?.layoutSubtreeIfNeeded()
    let previewHeight = pane.testPairedPreview.frame.height
    #expect(
      pane.testSplitView.autosaveName == "WorkspaceContentPane.\(externalID)")
    first.setContentSize(NSSize(width: 1100, height: 800))
    first.contentView?.layoutSubtreeIfNeeded()
    #expect(abs(pane.testPairedPreview.frame.height - previewHeight) < 0.5)
    pane.testSplitView.setPosition(100, ofDividerAt: 0)
    first.contentView?.layoutSubtreeIfNeeded()
    #expect(editorDocument.frame.height < pane.testEditorScrollView.contentView.bounds.height)
    #expect(editorDocument.frame.minY == 0)
    #expect(pane.testEditorScrollView.contentView.bounds.minY == 0)
    let reopened = makeWindow(
      storeService: state, appletData: data,
      url: URL(fileURLWithPath: "/tmp/Renamed-\(UUID()).ldtxworkspace"), externalID: externalID)
    defer { reopened.close() }
    let split = reopened.contentPane.testSplitView
    #expect(split.autosaveName == pane.testSplitView.autosaveName)
    #expect(changes == 0)
    pane.testPairedPreview.stop()
    #expect(pane.testPairedPreview.metalView.delegate == nil)
    #expect(pane.testPairedPreview.metalView.isPaused)
  }

  @Test func initialDividerRestoresAndPreservesDraggedHeight() throws {
    let externalID = UUID().uuidString.lowercased()
    let first = makeWindow(externalID: externalID)
    defer { first.close() }
    first.orderFront(nil)
    first.contentView?.layoutSubtreeIfNeeded()
    let split = first.contentPane.testSplitView
    #expect(abs(split.arrangedSubviews[0].frame.height - 280) < 0.5)

    let initialHeight = split.arrangedSubviews[0].frame.height
    let start = NSPoint(x: split.bounds.midX, y: initialHeight + split.dividerThickness / 2)
    let end = NSPoint(x: start.x, y: 360)
    let timestamp = ProcessInfo.processInfo.systemUptime
    let down = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: split.convert(start, to: nil), modifierFlags: [],
        timestamp: timestamp, windowNumber: first.windowNumber, context: nil,
        eventNumber: 1, clickCount: 1, pressure: 1))
    for type in [NSEvent.EventType.leftMouseDragged, .leftMouseUp] {
      let event = try #require(
        NSEvent.mouseEvent(
          with: type, location: split.convert(end, to: nil), modifierFlags: [],
          timestamp: timestamp + 0.01, windowNumber: first.windowNumber, context: nil,
          eventNumber: 2, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
      NSApplication.shared.postEvent(event, atStart: false)
    }
    split.mouseDown(with: down)
    first.contentView?.layoutSubtreeIfNeeded()
    let draggedHeight = split.arrangedSubviews[0].frame.height
    #expect(abs(draggedHeight - 360) < 1)

    for height: CGFloat in [800, 700] {
      first.setContentSize(NSSize(width: 1062, height: height))
      first.contentView?.layoutSubtreeIfNeeded()
      #expect(abs(split.arrangedSubviews[0].frame.height - draggedHeight) < 0.5)
    }
    first.close()
    let reopened = makeWindow(externalID: externalID)
    defer { reopened.close() }
    reopened.orderFront(nil)
    reopened.contentView?.layoutSubtreeIfNeeded()
    #expect(
      abs(reopened.contentPane.testPairedPreview.frame.height - draggedHeight) < 1)
    reopened.setContentSize(NSSize(width: 1100, height: 850))
    reopened.contentView?.layoutSubtreeIfNeeded()
    #expect(
      abs(reopened.contentPane.testPairedPreview.frame.height - draggedHeight) < 1)
  }

  private func drainTasks() async {
    // The action creates a main-actor task; yield until it has run.
    for _ in 0..<10 { await Task.yield() }
  }

  private func makeWindow(
    storeService: WorkspaceStoreService? = nil,
    dispatcher: (any WorkspaceRuntimeActions)? = nil,
    appletData: WorkspaceAppletData? = nil,
    url: URL? = nil,
    externalID: String = UUID().uuidString.lowercased()
  ) -> WorkspaceWindow {
    let document = WorkspaceDocument()
    let state = storeService ?? document.storeService
    state.externalID = externalID
    state.appletData = appletData ?? WorkspaceAppletData()
    state.runtimeActions = dispatcher
    let renderer = ProgramPairPreviewRenderer(
      landscapeRuntime: ProgramRuntime(
        captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
        lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry()),
      portraitRuntime: ProgramRuntime(
        captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
        lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry()),
      landscapeSize: CGSize(width: 16, height: 9), portraitSize: CGSize(width: 9, height: 16),
      prefersColor: true)
    let preview = ProgramCanvasPairedPreview(
      device: renderer.device, delegate: renderer,
      onSelectLandscape: { state.selectedAudioMix = .landscape },
      onSelectPortrait: { state.selectedAudioMix = .portrait })
    return WorkspaceWindow(
      url: url ?? URL(fileURLWithPath: "/tmp/Toolbar-\(UUID()).ldtxworkspace"),
      deviceRegistry: DeviceRegistryService(), appletData: state.appletData,
      storeService: state, documentReference: DocumentReference(document), pairedPreview: preview)

  }
}

@MainActor
@Observable
private final class ToolbarDispatcher: WorkspaceRuntimeActions {
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

@MainActor
extension WorkspaceContentPane {
  fileprivate var testSplitView: NSSplitView { view as! NSSplitView }
  fileprivate var testPairedPreview: ProgramCanvasPairedPreview {
    testSplitView.arrangedSubviews[0] as! ProgramCanvasPairedPreview
  }
  fileprivate var testEditorScrollView: NSScrollView {
    testSplitView.arrangedSubviews[1] as! NSScrollView
  }
  fileprivate var testVideoTabs: NSTabViewController {
    children.first { $0 is NSTabViewController } as! NSTabViewController
  }
  fileprivate var testAudioMixEditor: AudioMixEditor {
    children.first { $0 is AudioMixEditor } as! AudioMixEditor
  }
}
