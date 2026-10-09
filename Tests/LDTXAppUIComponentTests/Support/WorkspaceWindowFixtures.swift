// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXDeviceRegistry
import LDTXProgramRuntime
import LDTXProtos
import LDTXTaskQueue
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletModel
@testable import LDTXWorkspaceAppletUI
import Observation
import SwiftUI
import Testing

@MainActor
func drainWorkspaceTestTasks() async {
  // The action creates a main-actor task; yield until it has run.
  for _ in 0..<10 { await Task.yield() }
}

@MainActor
func settleWorkspaceToolbar(_ window: NSWindow) async {
  // SwiftUI creates accessibility nodes lazily, even in hostless component tests.
  NSApp.accessibilitySetValue(
    true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
  window.contentView?.layoutSubtreeIfNeeded()
  try? await Task.sleep(for: .milliseconds(100))
}

@MainActor
func performWorkspaceToolbarAction(_ item: NSToolbarItem) throws {
  let action = try #require(item.action)
  #expect(NSApp.sendAction(action, to: item.target, from: item))
}

@MainActor
func makeWorkspaceTestWindow(
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
  document.fileURL = url ?? URL(fileURLWithPath: "/tmp/Toolbar-\(UUID()).ldtxworkspace")
  return WorkspaceWindow(
    document: document, appletData: state.appletData, storeService: state,
    deviceRegistry: DeviceRegistryService(), pairedPreview: preview)

}

@MainActor
@Observable
final class ToolbarDispatcher: WorkspaceRuntimeActions {
  var failScreenshot = false
  var screenshotFiles: [WorkspaceScreenshot] = []
  var actions: [String] = []
  var failStart = false
  func startOutput() async throws {
    actions.append("start")
    if failStart { throw CocoaError(.fileReadNoSuchFile) }
  }
  func pauseOutput() async { actions.append("pause") }
  func stopOutput() async { actions.append("stop") }
  func synchronizeAudioMonitor() {}
  func synchronizeCaptureInputs(
    availableCameraIDs: Set<String>, completionHandler: @escaping @Sendable (Set<String>) -> Void
  ) { completionHandler([]) }
  func removeProgram(internalID: UInt64) throws {}
  func selectProgram(internalID: UInt64) throws {}
  func updateProgramRuntimes() {}
  func updateMixPreferences() {}
  func captureScreenshots() throws -> [WorkspaceScreenshot] {
    actions.append("screenshot")
    if failScreenshot { throw CocoaError(.fileWriteUnknown) }
    return screenshotFiles
  }
  func openScreenshotsDirectory() { actions.append("screenshotsFolder") }
}

@MainActor
extension WorkspaceContentPane {
  var testSplitView: NSSplitView { view as! NSSplitView }
  var testPairedPreview: ProgramCanvasPairedPreview {
    testSplitView.arrangedSubviews[0] as! ProgramCanvasPairedPreview
  }
  var testEditorScrollView: NSScrollView {
    testSplitView.arrangedSubviews[1] as! NSScrollView
  }
  var testVideoTabs: NSTabViewController {
    children.first { $0 is NSTabViewController } as! NSTabViewController
  }
  var testAudioMixEditor: AudioMixEditor {
    children.first { $0 is AudioMixEditor } as! AudioMixEditor
  }
}
