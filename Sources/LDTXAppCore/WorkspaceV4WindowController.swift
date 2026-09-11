// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppKitUI
import LDTXProgramRuntime
import LDTXWorkspace
import SwiftUI

/// The native window for a Version 4 Workspace. It is deliberately separate
/// from `WorkspaceWindowController`, whose view model is the V3 model.
@MainActor
final class WorkspaceV4WindowController: NSWindowController {
  let session: WorkspaceV4RuntimeSession
  let request: WorkspaceWindowRequest

  init(request: WorkspaceWindowRequest, lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry) {
    self.request = request
    session = WorkspaceV4RuntimeSession(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator())
    let split = PaneSplitViewController(
      sidebar: paneHost(WorkspaceV4Sidebar(session: session)),
      content: paneHost(WorkspaceV4Content(session: session)),
      inspector: paneHost(WorkspaceV4Inspector(session: session)),
      sidebarCanCollapse: true
    )
    let window = PaneWindow(contentViewController: split)
    window.title = "Workspace"
    window.titleVisibility = .hidden
    window.setContentSize(NSSize(width: 1062, height: 700))
    window.center()
    window.isReleasedWhenClosed = false
    window.toolbarStyle = .unified
    super.init(window: window)
    split.setInitialWidths(sidebar: 240, content: 480)
    session.installRuntime(
      AppFeatureRegistry.provider.makeProgramRuntime(
        captureSessionCoordinator: session.captureSessionCoordinator,
        programPreferencesState: ProgramPreferencesState(),
        lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry),
      role: .landscape)
    session.installRuntime(
      AppFeatureRegistry.provider.makeProgramRuntime(
        captureSessionCoordinator: session.captureSessionCoordinator,
        programPreferencesState: ProgramPreferencesState(),
        lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry),
      role: .portrait)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  func start() {
    do {
      switch request.source {
      case .new:
        try session.create(displayName: "Untitled Workspace")
      case .file(let url):
        try session.open(at: url)
        window?.title = url.deletingPathExtension().lastPathComponent
        window?.representedURL = url
      }
    } catch {
      present(error: error)
    }
  }

  func save() {
    guard let url = session.url else { saveAs(); return }
    do { try session.save(to: url) } catch { present(error: error) }
  }

  func saveAs() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.ldtxWorkspace]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "Workspace.ldtxworkspace"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try session.save(to: url)
      window?.title = url.deletingPathExtension().lastPathComponent
      window?.representedURL = session.url
    } catch { present(error: error) }
  }

  private func present(error: Error) {
    let alert = NSAlert(error: error)
    guard let window else { alert.runModal(); return }
    alert.beginSheetModal(for: window)
  }
}

private struct WorkspaceV4Sidebar: View {
  @Bindable var session: WorkspaceV4RuntimeSession

  var body: some View {
    List {
      Section("Programs") {
        ForEach(session.store.workspace.definition.definition.programs, id: \.internalID) { program in
          Button(program.displayName) { session.selectedProgramInternalID = program.internalID }
            .buttonStyle(.plain)
        }
      }
      Section("Input Devices") {
        ForEach(session.store.workspace.definition.definition.inputDevices.indices, id: \.self) { index in
          Text(inputLabel(session.store.workspace.definition.definition.inputDevices[index]))
        }
      }
      Section("Video Components") {
        ForEach(session.store.workspace.definition.definition.videoComponents.indices, id: \.self) { index in
          Text(componentLabel(session.store.workspace.definition.definition.videoComponents[index]))
        }
      }
    }
    .listStyle(.sidebar)
  }

  private func inputLabel(_ input: Ldtx_Workspace_V4_InputDeviceWrapper) -> String {
    switch input.definition {
    case .videoDevice(let device): device.displayName
    case .audioDevice(let device): device.displayName
    case nil: "Invalid Input Device"
    }
  }

  private func componentLabel(_ component: Ldtx_Workspace_V4_VideoComponentWrapper) -> String {
    switch component.definition {
    case .vfxSource(let value): value.displayName
    case .solidColorFill(let value): value.displayName
    case .linearGradientFill(let value): value.displayName
    case .radialGradientFill(let value): value.displayName
    case .conicGradientFill(let value): value.displayName
    case .clock(let value): value.displayName
    case .testPattern(let value): value.displayName
    case nil: "Invalid Video Component"
    }
  }
}

private struct WorkspaceV4Content: View {
  @Bindable var session: WorkspaceV4RuntimeSession
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(session.store.workspace.definition.definition.displayName)
        .font(.title2.weight(.semibold))
      HStack {
        Button("Add Program") { addProgram() }
        Button("Add Video Input") { addVideoInput() }
        Button("Add Audio Input") { addAudioInput() }
      }
      if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
      Spacer()
    }
    .padding(20)
  }

  private func addProgram() { perform { try session.store.addProgram(displayName: "Program") } }
  private func addVideoInput() { perform { try session.store.addVideoInputDevice(displayName: "Video Input") } }
  private func addAudioInput() { perform { try session.store.addAudioInputDevice(displayName: "Audio Input") } }
  private func perform(_ action: () throws -> UInt64) {
    do {
      let id = try action()
      if session.selectedProgramInternalID == nil,
        session.store.workspace.definition.definition.programs.contains(where: { $0.internalID == id })
      {
        session.selectedProgramInternalID = id
      } else {
        session.updateRuntimes()
      }
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }
}

private struct WorkspaceV4Inspector: View {
  @Bindable var session: WorkspaceV4RuntimeSession
  var body: some View {
    VStack(alignment: .leading) {
      Text("Workspace V4").font(.headline)
      Text(session.isDirty ? "Unsaved changes" : "Saved")
        .foregroundStyle(.secondary)
      Spacer()
    }
    .padding(16)
  }
}
