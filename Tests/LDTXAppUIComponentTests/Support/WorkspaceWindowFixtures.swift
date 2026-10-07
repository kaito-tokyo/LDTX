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

@MainActor
func drainWorkspaceTestTasks() async {
  // The action creates a main-actor task; yield until it has run.
  for _ in 0..<10 { await Task.yield() }
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
  return WorkspaceWindow(
    url: url ?? URL(fileURLWithPath: "/tmp/Toolbar-\(UUID()).ldtxworkspace"),
    deviceRegistry: DeviceRegistryService(), appletData: state.appletData,
    storeService: state, documentReference: DocumentReference(document), pairedPreview: preview)

}

@MainActor
@Observable
final class ToolbarDispatcher: WorkspaceRuntimeActions {
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
  func removeProgram(internalID: UInt64) throws {}
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
