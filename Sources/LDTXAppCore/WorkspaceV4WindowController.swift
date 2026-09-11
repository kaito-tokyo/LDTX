// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppKitUI
import LDTXAppUI
import LDTXCapture
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
import SwiftUI

/// The native window for a Version 4 Workspace. It is deliberately separate
/// from `WorkspaceWindowController`, whose view model is the V3 model.
@MainActor
final class WorkspaceV4WindowController: NSWindowController, NSWindowDelegate {
  let session: WorkspaceV4RuntimeSession
  let request: WorkspaceWindowRequest
  var identityChanged: ((WorkspaceWindowRequest) -> Void)?
  private var isClosingAfterConfirmation = false

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
    window.delegate = self
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
      identityChanged?(WorkspaceWindowRequest.file(url))
    } catch { present(error: error) }
  }

  func closeWorkspace() {
    session.close()
  }

  func windowWillClose(_ notification: Notification) {
    session.close()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard !isClosingAfterConfirmation, session.isDirty else { return true }

    let alert = NSAlert()
    alert.messageText = "Save changes to this Workspace?"
    alert.informativeText = "Your unsaved Workspace changes will be lost if you close without saving."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Discard")
    alert.alertStyle = .warning

    switch alert.runModal() {
    case .alertFirstButtonReturn:
      save()
      guard !session.isDirty else { return false }
      isClosingAfterConfirmation = true
      return true
    case .alertThirdButtonReturn:
      isClosingAfterConfirmation = true
      return true
    default:
      return false
    }
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
  @State private var cameras: [CameraCaptureSource] = []
  @State private var audioDevices: [AudioCaptureSource] = []
  @State private var selectedVideoDeviceIDs: [UInt64: String] = [:]
  @State private var selectedAudioDeviceIDs: [UInt64: String] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(session.store.workspace.definition.definition.displayName)
        .font(.title2.weight(.semibold))
      HStack {
        Button("Add Program") { addProgram() }
        Button("Add Video Input") { addVideoInput() }
        Button("Add Audio Input") { addAudioInput() }
        Button("Add VFX Source") { addVFXSource() }
          .disabled(firstVideoInputID == nil)
        Button("Add Solid Color") { addSolidColor() }
      }
      if let landscapeRuntime = session.runtime(for: .landscape),
        let portraitRuntime = session.runtime(for: .portrait)
      {
        WorkspaceRuntimeCanvasPairPreview(
          landscapeRuntime: landscapeRuntime,
          portraitRuntime: portraitRuntime,
          landscapeSize: canvasSize(for: landscapeRuntime, fallback: CGSize(width: 1_920, height: 1_080)),
          portraitSize: canvasSize(for: portraitRuntime, fallback: CGSize(width: 1_080, height: 1_920))
        )
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("workspaceV4CanvasPreview")
      }
      videoLayers
      inputDeviceAssignments
      if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
      Spacer()
    }
    .padding(20)
    .onAppear { refreshCaptureDevices() }
  }

  private func addProgram() { perform { try session.store.addProgram(displayName: "Program") } }
  private func addVideoInput() { perform { try session.store.addVideoInputDevice(displayName: "Video Input") } }
  private func addAudioInput() { perform { try session.store.addAudioInputDevice(displayName: "Audio Input") } }
  private func addVFXSource() {
    guard let inputID = firstVideoInputID else { return }
    do {
      let componentID = try session.store.addVFXSource(
        displayName: "VFX Source", inputDeviceInternalID: inputID)
      addToSelectedProgram(componentID)
      session.updateRuntimes()
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }

  private func addSolidColor() {
    do {
      var color = Ldtx_Workspace_V4_ExtendedSrgbColor()
      color.red = 0.2
      color.green = 0.2
      color.blue = 0.2
      color.alpha = 1
      let componentID = try session.store.addSolidColorFill(displayName: "Solid Color", color: color)
      addToSelectedProgram(componentID)
      session.updateRuntimes()
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }

  private func addToSelectedProgram(_ videoLayerInternalID: UInt64) {
    guard let programID = session.selectedProgramInternalID else { return }
    for role in ProgramCanvasRole.allCases {
      let existing = session.store.workspace.definition.definition.programs.first {
        $0.internalID == programID
      }.map { role == .landscape ? $0.landscapeVideoLayerInternalIds : $0.portraitVideoLayerInternalIds }
        ?? []
      try? session.store.setVideoLayerOrder(
        existing + [videoLayerInternalID], forProgramInternalID: programID, role: role)
    }
  }

  @ViewBuilder
  private var videoLayers: some View {
    if let selectedProgram {
      GroupBox("Video Layers") {
        VStack(alignment: .leading) {
          videoLayerList(for: selectedProgram, role: .landscape, title: "Landscape")
          videoLayerList(for: selectedProgram, role: .portrait, title: "Portrait")
        }
      }
    }
  }

  private func videoLayerList(
    for program: Ldtx_Workspace_V4_ProgramDefinition,
    role: ProgramCanvasRole,
    title: String
  ) -> some View {
    let layerIDs = role == .landscape
      ? program.landscapeVideoLayerInternalIds : program.portraitVideoLayerInternalIds
    return VStack(alignment: .leading) {
      Text(title).font(.headline)
      if layerIDs.isEmpty {
        Text("No video layers").foregroundStyle(.secondary)
      }
      ForEach(Array(layerIDs.enumerated()), id: \.element) { index, internalID in
        HStack {
          Text(videoLayerDisplayName(for: internalID))
          Spacer()
          Button { moveVideoLayer(in: program, role: role, from: index, offset: -1) } label: {
            Image(systemName: "arrow.up")
          }
          .disabled(index == 0)
          Button { moveVideoLayer(in: program, role: role, from: index, offset: 1) } label: {
            Image(systemName: "arrow.down")
          }
          .disabled(index == layerIDs.count - 1)
          Button { removeVideoLayer(in: program, role: role, at: index) } label: {
            Image(systemName: "minus")
          }
          .accessibilityLabel("Remove \(videoLayerDisplayName(for: internalID)) from \(title)")
        }
      }
    }
  }

  private var selectedProgram: Ldtx_Workspace_V4_ProgramDefinition? {
    guard let id = session.selectedProgramInternalID else { return nil }
    return session.store.workspace.definition.definition.programs.first { $0.internalID == id }
  }

  private func moveVideoLayer(
    in program: Ldtx_Workspace_V4_ProgramDefinition,
    role: ProgramCanvasRole,
    from index: Int,
    offset: Int
  ) {
    var layerIDs = role == .landscape
      ? program.landscapeVideoLayerInternalIds : program.portraitVideoLayerInternalIds
    let destination = index + offset
    guard layerIDs.indices.contains(index), layerIDs.indices.contains(destination) else { return }
    layerIDs.swapAt(index, destination)
    performLayerOrderUpdate(layerIDs, for: program.internalID, role: role)
  }

  private func removeVideoLayer(
    in program: Ldtx_Workspace_V4_ProgramDefinition,
    role: ProgramCanvasRole,
    at index: Int
  ) {
    var layerIDs = role == .landscape
      ? program.landscapeVideoLayerInternalIds : program.portraitVideoLayerInternalIds
    guard layerIDs.indices.contains(index) else { return }
    layerIDs.remove(at: index)
    performLayerOrderUpdate(layerIDs, for: program.internalID, role: role)
  }

  private func performLayerOrderUpdate(
    _ layerIDs: [UInt64], for programInternalID: UInt64, role: ProgramCanvasRole
  ) {
    do {
      try session.store.setVideoLayerOrder(
        layerIDs, forProgramInternalID: programInternalID, role: role)
      session.updateRuntimes()
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }

  private func videoLayerDisplayName(for internalID: UInt64) -> String {
    if let input = session.store.workspace.definition.definition.inputDevices.first(where: { input in
      switch input.definition {
      case .videoDevice(let device): device.internalID == internalID
      case .audioDevice, nil: false
      }
    }), case .videoDevice(let device)? = input.definition {
      return device.displayName
    }
    if let component = session.store.workspace.definition.definition.videoComponents.first(where: {
      componentInternalID($0) == internalID
    }) {
      return componentDisplayName(component)
    }
    return "Missing Video Layer"
  }

  private func componentInternalID(_ component: Ldtx_Workspace_V4_VideoComponentWrapper) -> UInt64? {
    switch component.definition {
    case .vfxSource(let value): value.internalID
    case .solidColorFill(let value): value.internalID
    case .linearGradientFill(let value): value.internalID
    case .radialGradientFill(let value): value.internalID
    case .conicGradientFill(let value): value.internalID
    case .clock(let value): value.internalID
    case .testPattern(let value): value.internalID
    case nil: nil
    }
  }

  private func componentDisplayName(_ component: Ldtx_Workspace_V4_VideoComponentWrapper) -> String {
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

  private var firstVideoInputID: UInt64? {
    session.store.workspace.definition.definition.inputDevices.compactMap { input -> UInt64? in
      guard case .videoDevice(let device)? = input.definition else { return nil }
      return device.internalID
    }.first
  }

  @ViewBuilder
  private var inputDeviceAssignments: some View {
    if !videoInputs.isEmpty || !audioInputs.isEmpty {
      GroupBox("Physical Devices") {
        VStack(alignment: .leading) {
          ForEach(videoInputs, id: \.internalID) { input in
            Picker(input.displayName, selection: videoDeviceBinding(for: input.internalID)) {
              Text("No camera").tag("")
              ForEach(cameras) { camera in
                Text(camera.name).tag(camera.id)
              }
            }
          }
          ForEach(audioInputs, id: \.internalID) { input in
            Picker(input.displayName, selection: audioDeviceBinding(for: input.internalID)) {
              Text("No audio device").tag("")
              ForEach(audioDevices) { device in
                Text(device.name).tag(device.id)
              }
            }
          }
          Button("Refresh Physical Devices") { refreshCaptureDevices() }
        }
      }
    }
  }

  private var videoInputs: [Ldtx_Workspace_V4_VideoInputDevice] {
    session.store.workspace.definition.definition.inputDevices.compactMap { input in
      guard case .videoDevice(let device)? = input.definition else { return nil }
      return device
    }
  }

  private var audioInputs: [Ldtx_Workspace_V4_AudioInputDevice] {
    session.store.workspace.definition.definition.inputDevices.compactMap { input in
      guard case .audioDevice(let device)? = input.definition else { return nil }
      return device
    }
  }

  private func videoDeviceBinding(for internalID: UInt64) -> Binding<String> {
    Binding(
      get: { selectedVideoDeviceIDs[internalID] ?? "" },
      set: { id in
        selectedVideoDeviceIDs[internalID] = id
        session.setPhysicalVideoDeviceID(id.isEmpty ? nil : id, for: internalID)
        synchronizeCaptureInputs()
      })
  }

  private func audioDeviceBinding(for internalID: UInt64) -> Binding<String> {
    Binding(
      get: { selectedAudioDeviceIDs[internalID] ?? "" },
      set: { id in
        selectedAudioDeviceIDs[internalID] = id
        session.setPhysicalAudioDeviceID(id.isEmpty ? nil : id, for: internalID)
        synchronizeCaptureInputs()
      })
  }

  private func refreshCaptureDevices() {
    let service = DefaultCaptureDeviceService()
    cameras = service.availableCameras()
    audioDevices = service.availableAudioDevices()
    selectedVideoDeviceIDs = Dictionary(uniqueKeysWithValues: videoInputs.compactMap { input in
      session.physicalVideoDeviceID(for: input.internalID).map { (input.internalID, $0) }
    })
    selectedAudioDeviceIDs = Dictionary(uniqueKeysWithValues: audioInputs.compactMap { input in
      session.physicalAudioDeviceID(for: input.internalID).map { (input.internalID, $0) }
    })
    synchronizeCaptureInputs()
  }

  private func synchronizeCaptureInputs() {
    session.synchronizeCaptureInputs(availableCameraIDs: Set(cameras.map(\.id))) { _ in }
  }

  private func canvasSize(for runtime: ProgramRuntime, fallback: CGSize) -> CGSize {
    runtime.programState.read { configuration in
      guard let configuration, configuration.canvasWidth > 0, configuration.canvasHeight > 0 else {
        return fallback
      }
      return CGSize(width: configuration.canvasWidth, height: configuration.canvasHeight)
    }
  }

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
