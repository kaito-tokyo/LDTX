// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXDeviceRegistry
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletInterface
import LDTXWorkspaceAppletUI
import Observation
import Testing

@Suite(.serialized)
@MainActor
struct WorkspaceToolbarSystemTestSuite {
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
    #expect(first.titleVisibility == .hidden)
    #expect(toolbar.displayMode == .iconOnly)
    #expect(first.styleMask.contains(.fullSizeContentView))
    #expect(
      toolbar.items.map(\.itemIdentifier) == [
        .init("workspace.sidebar"), .sidebarTrackingSeparator,
        .init("workspace.stopOutput"), .init("workspace.toggleOutput"), .flexibleSpace,
        .inspectorTrackingSeparator, .flexibleSpace, .init("workspace.inspector"),
      ])
    #expect(first.contentLayoutRect.size == NSSize(width: 1062, height: 700))
    let split = try #require(first.contentViewController as? PaneSplitViewController)
    let other = try #require(second.contentViewController as? PaneSplitViewController)
    split.setInitialWidths(sidebar: 240, content: 480)
    split.view.layoutSubtreeIfNeeded()
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

  private func drainTasks() async {
    // The action creates a main-actor task; yield until it has run.
    for _ in 0..<10 { await Task.yield() }
  }

  private func makeWindow(
    uiState: WorkspaceUIState? = nil,
    dispatcher: (any WorkspaceDispatcherProtocol)? = nil
  ) -> WorkspaceWindow {
    let document = WorkspaceDocument()
    return WorkspaceWindow(
      url: URL(fileURLWithPath: "/tmp/Toolbar-\(UUID()).ldtxworkspace"),
      deviceRegistry: DeviceRegistryService(), appletData: WorkspaceAppletData(),
      dispatcher: dispatcher ?? WorkspaceDispatcher(), uiState: uiState ?? document.uiState,
      documentReference: DocumentReference(document))
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
  func updateProgramRuntimes() {}
  func updateMixPreferences() {}
  func captureScreenshots() throws -> [URL] { [] }
  func openScreenshotsDirectory() {}
}
