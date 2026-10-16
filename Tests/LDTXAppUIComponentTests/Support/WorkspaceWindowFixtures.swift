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
import MetalKit
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
  let menuItem = try #require(item.menuFormRepresentation)
  guard menuItem.isEnabled else { return }
  let action = try #require(menuItem.action)
  #expect(NSApp.sendAction(action, to: menuItem.target, from: menuItem))
}

@MainActor
func makeWorkspaceTestWindow(
  stateService: WorkspaceStateService? = nil,
  dispatcher: (any WorkspaceRuntimeActions)? = nil,
  reportError: @escaping (Error) -> Void = { _ in },
  appletData: WorkspaceAppletData? = nil,
  url: URL? = nil,
  documentContext: (any WorkspaceDocumentContext)? = nil,
  externalID: String = UUID().uuidString.lowercased()
) -> WorkspaceTestWindow {
  let document = WorkspaceDocument()
  let state = stateService ?? document.stateService
  state.externalID = externalID
  let data = appletData ?? WorkspaceAppletData()
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
    metalView: MTKView(frame: .zero, device: renderer.device), delegate: renderer,
    onSelectLandscape: { state.selectedAudioMix = .landscape },
    onSelectPortrait: { state.selectedAudioMix = .portrait })
  let context =
    documentContext
    ?? WorkspaceTestDocumentContext(
      fileURL: url ?? URL(fileURLWithPath: "/tmp/Toolbar-\(UUID()).ldtxworkspace"))
  return WorkspaceTestWindow(
    stateService: state, appletData: data, deviceRegistry: DeviceRegistryService(),
    peakMeter: .init(), pairedPreview: preview, runtimeActions: { dispatcher }, document: context)
}

@MainActor
private final class WorkspaceTestDocumentContext: WorkspaceDocumentContext {
  let fileURL: URL?
  init(fileURL: URL?) { self.fileURL = fileURL }
}

@MainActor
@Observable
final class ToolbarDispatcher: WorkspaceRuntimeActions {
  var classificationHandler: (() async throws -> String)?
  func classify(
    vision: Ldtx_Workspace_V4_LdtxSceneDetectorVision, modelURL: URL
  ) async throws -> String {
    if let classificationHandler { return try await classificationHandler() }
    return "Test classification"
  }

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
  func removeProgram(internalID: Int64) throws {}
  func selectProgram(internalID: Int64) throws {}
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
  var testPairedPreview: ProgramCanvasPairedPreview { pairedPreview }
}
