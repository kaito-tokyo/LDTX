// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletData
import LDTXWorkspaceAppletInterface
import SwiftUI
import UniformTypeIdentifiers

public struct WorkspaceV4Content: View {
  let store: any WorkspaceBundleStoreProtocol
  let session: any WorkspaceSessionProtocol
  let recordingSession: any WorkspaceRecordingSessionProtocol
  let deviceMappingAppletData: WorkspaceDeviceAppletData
  @Bindable var splitPaneStore: WorkspaceUIStore
  let saveBeforeStartingOutput: () throws -> Bool
  let synchronizeVision: () -> Void
  let synchronizeAudioMonitor: () -> Void
  @State private var errorMessage: String?
  @State private var cameras: [CameraCaptureSource] = []
  @State private var audioDevices: [AudioCaptureSource] = []
  @State private var selectedVideoDeviceIDs: [UInt64: String] = [:]
  @State private var selectedAudioDeviceIDs: [UInt64: String] = [:]

  public init(
    store: any WorkspaceBundleStoreProtocol,
    session: any WorkspaceSessionProtocol,
    recordingSession: any WorkspaceRecordingSessionProtocol,
    deviceMappingAppletData: WorkspaceDeviceAppletData,
    splitPaneStore: WorkspaceUIStore,
    saveBeforeStartingOutput: @escaping () throws -> Bool,
    synchronizeVision: @escaping () -> Void,
    synchronizeAudioMonitor: @escaping () -> Void
  ) {
    self.store = store
    self.session = session
    self.recordingSession = recordingSession
    self.deviceMappingAppletData = deviceMappingAppletData
    self.splitPaneStore = splitPaneStore
    self.saveBeforeStartingOutput = saveBeforeStartingOutput
    self.synchronizeVision = synchronizeVision
    self.synchronizeAudioMonitor = synchronizeAudioMonitor
  }

  public var body: some View {
    Group {
      if splitPaneStore.selectedItem == .preview {
        preview
      } else {
        ScrollView(.vertical) {
          VStack(alignment: .leading, spacing: 16) {
            Text(store.definition.displayName)
              .font(.title2.weight(.semibold))
            HStack {
              Button("Add Program") { addProgram() }.disabled(recordingSession.isRecording)
              Button("Add Video Input") { addVideoInput() }.disabled(recordingSession.isRecording)
              Button("Add Audio Input") { addAudioInput() }.disabled(recordingSession.isRecording)
              Button("Add VFX Source") { addVFXSource() }
                .disabled(firstVideoInputID == nil || recordingSession.isRecording)
              Menu("Add Video Component") {
                Button("Solid Color") { addSolidColor() }
                Button("Linear Gradient") { addLinearGradient() }
                Button("Radial Gradient") { addRadialGradient() }
                Button("Conic Gradient") { addConicGradient() }
                Divider()
                Button("Clock") { addClock() }
                Button("Test Pattern") { addTestPattern() }
              }
              .disabled(recordingSession.isRecording)
              Button("Add OCR Vision") { addOcrVision() }
                .disabled(firstVideoInputID == nil || recordingSession.isRecording)
              Button(recordingSession.isRecording ? "Stop Output" : "Start Output") {
                Task {
                  if recordingSession.isRecording {
                    await recordingSession.stop()
                  } else {
                    do {
                      if try saveBeforeStartingOutput() {
                        await recordingSession.start()
                      } else {
                        errorMessage = "Save this Workspace before starting output."
                      }
                    } catch {
                      errorMessage = error.localizedDescription
                    }
                  }
                }
              }
              if recordingSession.isRecording && recordingSession.isLocalRecording {
                Button("Capture Screenshot(s)") {
                  do { _ = try recordingSession.captureScreenshots() } catch {
                    errorMessage = error.localizedDescription
                  }
                }
                Button("Open Screenshots Folder") {
                  if let url = recordingSession.screenshotsDirectory {
                    NSWorkspace.shared.open(url)
                  }
                }
              }
            }
            videoLayers
            audioMix
            inputDeviceAssignments
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            if case .failed(let message) = recordingSession.state {
              Text(message).foregroundStyle(.red)
            }
            Spacer()
          }
          .padding(20)
        }
      }
    }
    .onAppear {
      refreshCaptureDevices()
      synchronizeAudioMonitor()
    }
    .onChange(of: session.url) { _, _ in
      refreshCaptureDevices()
      synchronizeAudioMonitor()
    }
  }

  @ViewBuilder
  private var preview: some View {
    if let landscapeRuntime = session.runtime(for: .landscape),
      let portraitRuntime = session.runtime(for: .portrait)
    {
      WorkspaceRuntimeCanvasPairPreview(
        landscapeRuntime: landscapeRuntime,
        portraitRuntime: portraitRuntime,
        landscapeSize: canvasSize(
          for: landscapeRuntime, fallback: CGSize(width: 1_920, height: 1_080)),
        portraitSize: canvasSize(
          for: portraitRuntime, fallback: CGSize(width: 1_080, height: 1_920))
      )
      .frame(maxWidth: .infinity)
      .accessibilityIdentifier("workspaceV4CanvasPreview")
    } else {
      ContentUnavailableView("Preview Unavailable", systemImage: "play.rectangle")
    }
  }

  private func addProgram() {
    do {
      let programID = try session.addProgram(displayName: uniqueProgramDisplayName("Program"))
      if store.selectedProgramInternalID == nil {
        store.selectedProgramInternalID = programID
      }
      session.updateRuntimes()
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
    synchronizeAudioMonitor()
  }
  private func addVideoInput() {
    perform { try session.addVideoInputDevice(displayName: uniqueDisplayName("Video Input")) }
  }
  private func addAudioInput() {
    perform { try session.addAudioInputDevice(displayName: uniqueDisplayName("Audio Input")) }
    synchronizeAudioMonitor()
  }
  private func addVFXSource() {
    guard let inputID = firstVideoInputID else { return }
    do {
      let componentID = try session.addVFXSource(
        displayName: uniqueDisplayName("VFX Source"), inputDeviceInternalID: inputID)
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
      let componentID = try session.addSolidColorFill(
        displayName: uniqueDisplayName("Solid Color"), color: color)
      addToSelectedProgram(componentID)
      session.updateRuntimes()
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }

  private func addClock() {
    do {
      let componentID = try session.addClock(displayName: uniqueDisplayName("Clock"))
      addToSelectedProgram(componentID)
      session.updateRuntimes()
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }

  private func addLinearGradient() {
    do {
      let componentID = try session.addLinearGradientFill(
        displayName: uniqueDisplayName("Linear Gradient"))
      addToSelectedProgram(componentID)
      session.updateRuntimes()
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }

  private func addRadialGradient() {
    do {
      let componentID = try session.addRadialGradientFill(
        displayName: uniqueDisplayName("Radial Gradient"))
      addToSelectedProgram(componentID)
      session.updateRuntimes()
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }

  private func addConicGradient() {
    do {
      let componentID = try session.addConicGradientFill(
        displayName: uniqueDisplayName("Conic Gradient"))
      addToSelectedProgram(componentID)
      session.updateRuntimes()
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }

  private func addTestPattern() {
    do {
      let componentID = try session.addTestPattern(
        displayName: uniqueDisplayName("Test Pattern"))
      addToSelectedProgram(componentID)
      session.updateRuntimes()
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }

  private func addOcrVision() {
    guard let inputID = firstVideoInputID else { return }
    perform {
      try session.addOcrVision(
        displayName: uniqueDisplayName("OCR Vision"), inputDeviceInternalID: inputID)
    }
    synchronizeVision()
  }

  private func addToSelectedProgram(_ videoLayerInternalID: UInt64) {
    guard let programID = store.selectedProgramInternalID else { return }
    for role in ProgramCanvasRole.allCases {
      let existing =
        store.definition.programs.first {
          $0.internalID == programID
        }.map {
          role == .landscape ? $0.landscapeVideoLayerInternalIds : $0.portraitVideoLayerInternalIds
        }
        ?? []
      try? session.setVideoLayerOrder(
        existing + [videoLayerInternalID], forProgramInternalID: programID, role: role)
    }
  }

  private func uniqueDisplayName(_ base: String) -> String {
    let definition = store.definition
    let names = Set(
      definition.inputDevices.compactMap { wrapper -> String? in
        switch wrapper.definition {
        case .videoDevice(let value): value.displayName
        case .audioDevice(let value): value.displayName
        case nil: nil
        }
      }
        + definition.videoComponents.compactMap { wrapper -> String? in
          switch wrapper.definition {
          case .solidColorFill(let value): value.displayName
          case .linearGradientFill(let value): value.displayName
          case .radialGradientFill(let value): value.displayName
          case .conicGradientFill(let value): value.displayName
          case .vfxSource(let value): value.displayName
          case .clock(let value): value.displayName
          case .testPattern(let value): value.displayName
          case nil: nil
          }
        }
        + definition.visions.compactMap { wrapper -> String? in
          guard case .ocrVision(let value)? = wrapper.definition else { return nil }
          return value.displayName
        }
        + definition.programs.map(\.displayName))
    guard names.contains(base) else { return base }
    var suffix = 2
    while names.contains("\(base) \(suffix)") { suffix += 1 }
    return "\(base) \(suffix)"
  }

  private func uniqueProgramDisplayName(_ base: String) -> String {
    let names = Set(store.definition.programs.map(\.displayName))
    guard names.contains(base) else { return base }
    var suffix = 2
    while names.contains("\(base) \(suffix)") { suffix += 1 }
    return "\(base) \(suffix)"
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
    let layerIDs =
      role == .landscape
      ? program.landscapeVideoLayerInternalIds : program.portraitVideoLayerInternalIds
    return VStack(alignment: .leading) {
      HStack {
        Text(title).font(.headline)
        Spacer()
        Menu("Add Video Layer") {
          ForEach(availableVideoLayerIDs(for: program, role: role), id: \.self) { internalID in
            Button(videoLayerDisplayName(for: internalID)) {
              addVideoLayer(internalID, to: program, role: role)
            }
          }
        }
        .disabled(
          recordingSession.isRecording
            || availableVideoLayerIDs(for: program, role: role).isEmpty)
      }
      if layerIDs.isEmpty {
        Text("No video layers").foregroundStyle(.secondary)
      }
      ForEach(Array(layerIDs.enumerated()), id: \.element) { index, internalID in
        VStack(alignment: .leading) {
          HStack {
            Text(videoLayerDisplayName(for: internalID))
            Spacer()
            Toggle(
              "Mute",
              isOn: videoLayerMuteBinding(
                layerInternalID: internalID, programInternalID: program.internalID, role: role)
            )
            .toggleStyle(.checkbox)
            Button {
              moveVideoLayer(in: program, role: role, from: index, offset: -1)
            } label: {
              Image(systemName: "arrow.up")
            }
            .disabled(recordingSession.isRecording || index == 0)
            Button {
              moveVideoLayer(in: program, role: role, from: index, offset: 1)
            } label: {
              Image(systemName: "arrow.down")
            }
            .disabled(recordingSession.isRecording || index == layerIDs.count - 1)
            Button {
              removeVideoLayer(in: program, role: role, at: index)
            } label: {
              Image(systemName: "minus")
            }
            .accessibilityLabel("Remove \(videoLayerDisplayName(for: internalID)) from \(title)")
            .disabled(recordingSession.isRecording)
          }
          WorkspaceV4LayerTransformEditor(
            store: store, session: session, programInternalID: program.internalID,
            role: role, videoLayerInternalID: internalID)
        }
      }
    }
  }

  private var selectedProgram: Ldtx_Workspace_V4_ProgramDefinition? {
    guard let id = store.selectedProgramInternalID else { return nil }
    return store.definition.programs.first { $0.internalID == id }
  }

  @ViewBuilder
  private var audioMix: some View {
    if let selectedProgram, !audioInputs.isEmpty {
      GroupBox("Audio Mix") {
        VStack(alignment: .leading) {
          audioMix(
            role: .landscape, title: "Landscape", programInternalID: selectedProgram.internalID)
          HStack {
            Text("Monitor").frame(width: 96, alignment: .leading)
            Slider(value: monitorVolumeBinding, in: -60...12)
          }
          ForEach(audioInputs, id: \.internalID) { input in
            Toggle("Monitor \(input.displayName)", isOn: monitorBinding(for: input.internalID))
              .toggleStyle(.checkbox)
          }
          Toggle(
            "Sync Landscape Mix to Portrait",
            isOn: Binding(
              get: { store.synchronizesLandscapeMixToPortrait(for: selectedProgram.internalID) },
              set: {
                store.setSynchronizesLandscapeMixToPortrait($0, for: selectedProgram.internalID)
                recordingSession.updateMixPreferences()
              }
            ))
          audioMix(
            role: .portrait, title: "Portrait", programInternalID: selectedProgram.internalID)
        }
      }
    }
  }

  private func audioMix(
    role: ProgramCanvasRole,
    title: String,
    programInternalID: UInt64
  ) -> some View {
    VStack(alignment: .leading) {
      Text(title).font(.headline)
      HStack {
        Text("Master").frame(width: 96, alignment: .leading)
        Slider(value: masterVolumeBinding(for: programInternalID, role: role), in: -60...12)
      }
      ForEach(audioInputs, id: \.internalID) { input in
        HStack {
          Text(input.displayName).frame(width: 96, alignment: .leading)
          Slider(
            value: audioGainBinding(
              for: input.internalID, programInternalID: programInternalID, role: role), in: -60...12
          )
          Toggle(
            "Mute",
            isOn: audioMuteBinding(
              for: input.internalID, programInternalID: programInternalID, role: role)
          )
          .toggleStyle(.checkbox)
        }
      }
    }
  }

  private func masterVolumeBinding(
    for programInternalID: UInt64,
    role: ProgramCanvasRole
  ) -> Binding<Double> {
    Binding(
      get: {
        let preference = store.preferences.programPreferences[
          programInternalID]
        return role == .landscape
          ? preference?.landscapeMasterVolume ?? 0 : preference?.portraitMasterVolume ?? 0
      },
      set: { value in
        try? session.setMasterVolume(value, programInternalID: programInternalID, role: role)
        session.updateRuntimes()
        recordingSession.updateMixPreferences()
        synchronizeAudioMonitor()
      })
  }

  private func audioGainBinding(
    for inputDeviceInternalID: UInt64,
    programInternalID: UInt64,
    role: ProgramCanvasRole
  ) -> Binding<Double> {
    Binding(
      get: {
        let preference = store.preferences.programPreferences[
          programInternalID]
        return role == .landscape
          ? preference?.landscapeAudioChannelGains[inputDeviceInternalID] ?? 0
          : preference?.portraitAudioChannelGains[inputDeviceInternalID] ?? 0
      },
      set: { value in
        try? session.setAudioChannelGain(
          value, forAudioInputDeviceInternalID: inputDeviceInternalID,
          programInternalID: programInternalID, role: role)
        session.updateRuntimes()
        recordingSession.updateMixPreferences()
        synchronizeAudioMonitor()
      })
  }

  private func audioMuteBinding(
    for inputDeviceInternalID: UInt64,
    programInternalID: UInt64,
    role: ProgramCanvasRole
  ) -> Binding<Bool> {
    Binding(
      get: {
        let preference = store.preferences.programPreferences[
          programInternalID]
        return role == .landscape
          ? preference?.landscapeAudioChannelMuted[inputDeviceInternalID] ?? false
          : preference?.portraitAudioChannelMuted[inputDeviceInternalID] ?? false
      },
      set: { value in
        try? session.setAudioChannelMuted(
          value, forAudioInputDeviceInternalID: inputDeviceInternalID,
          programInternalID: programInternalID, role: role)
        session.updateRuntimes()
        recordingSession.updateMixPreferences()
        synchronizeAudioMonitor()
      })
  }

  private var monitorVolumeBinding: Binding<Double> {
    Binding(
      get: { store.preferences.monitorVolume },
      set: { value in
        try? session.setMonitorVolume(value)
        synchronizeAudioMonitor()
      })
  }

  private func monitorBinding(for inputDeviceInternalID: UInt64) -> Binding<Bool> {
    Binding(
      get: { store.monitorsAudioInputDevice(inputDeviceInternalID) },
      set: { enabled in
        store.setMonitorsAudioInputDevice(enabled, for: inputDeviceInternalID)
        synchronizeAudioMonitor()
      })
  }

  private func moveVideoLayer(
    in program: Ldtx_Workspace_V4_ProgramDefinition,
    role: ProgramCanvasRole,
    from index: Int,
    offset: Int
  ) {
    guard !recordingSession.isRecording else { return }
    var layerIDs =
      role == .landscape
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
    guard !recordingSession.isRecording else { return }
    var layerIDs =
      role == .landscape
      ? program.landscapeVideoLayerInternalIds : program.portraitVideoLayerInternalIds
    guard layerIDs.indices.contains(index) else { return }
    layerIDs.remove(at: index)
    performLayerOrderUpdate(layerIDs, for: program.internalID, role: role)
  }

  private func availableVideoLayerIDs(
    for program: Ldtx_Workspace_V4_ProgramDefinition,
    role: ProgramCanvasRole
  ) -> [UInt64] {
    let usedIDs = Set(
      role == .landscape
        ? program.landscapeVideoLayerInternalIds : program.portraitVideoLayerInternalIds)
    let inputIDs = store.definition.inputDevices.compactMap {
      input -> UInt64? in
      guard case .videoDevice(let device)? = input.definition else { return nil }
      return device.internalID
    }
    let componentIDs = store.definition.videoComponents.compactMap {
      componentInternalID($0)
    }
    return (inputIDs + componentIDs).filter { !usedIDs.contains($0) }
  }

  private func addVideoLayer(
    _ internalID: UInt64,
    to program: Ldtx_Workspace_V4_ProgramDefinition,
    role: ProgramCanvasRole
  ) {
    guard !recordingSession.isRecording else { return }
    let existing =
      role == .landscape
      ? program.landscapeVideoLayerInternalIds : program.portraitVideoLayerInternalIds
    performLayerOrderUpdate(existing + [internalID], for: program.internalID, role: role)
  }

  private func performLayerOrderUpdate(
    _ layerIDs: [UInt64], for programInternalID: UInt64, role: ProgramCanvasRole
  ) {
    do {
      try session.setVideoLayerOrder(
        layerIDs, forProgramInternalID: programInternalID, role: role)
      session.updateRuntimes()
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }

  private func videoLayerMuteBinding(
    layerInternalID: UInt64,
    programInternalID: UInt64,
    role: ProgramCanvasRole
  ) -> Binding<Bool> {
    Binding(
      get: {
        let preference = store.preferences.programPreferences[
          programInternalID]
        switch role {
        case .landscape: return preference?.landscapeVideoLayerMuted[layerInternalID] ?? false
        case .portrait: return preference?.portraitVideoLayerMuted[layerInternalID] ?? false
        }
      },
      set: { muted in
        try? session.setVideoLayerMuted(
          muted, forVideoLayerInternalID: layerInternalID,
          programInternalID: programInternalID, role: role)
        session.updateRuntimes()
      }
    )
  }

  private func videoLayerDisplayName(for internalID: UInt64) -> String {
    if let input = store.definition.inputDevices.first(where: {
      input in
      switch input.definition {
      case .videoDevice(let device): device.internalID == internalID
      case .audioDevice, nil: false
      }
    }), case .videoDevice(let device)? = input.definition {
      return device.displayName
    }
    if let component = store.definition.videoComponents.first(where: {
      componentInternalID($0) == internalID
    }) {
      return componentDisplayName(component)
    }
    return "Missing Video Layer"
  }

  private func componentInternalID(_ component: Ldtx_Workspace_V4_VideoComponentWrapper) -> UInt64?
  {
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

  private func componentDisplayName(_ component: Ldtx_Workspace_V4_VideoComponentWrapper) -> String
  {
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
    store.definition.inputDevices.compactMap { input -> UInt64? in
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
            .disabled(recordingSession.isRecording)
          }
          Button("Refresh Physical Devices") { refreshCaptureDevices() }
        }
      }
    }
  }

  private var videoInputs: [Ldtx_Workspace_V4_VideoInputDevice] {
    store.definition.inputDevices.compactMap { input in
      guard case .videoDevice(let device)? = input.definition else { return nil }
      return device
    }
  }

  private var audioInputs: [Ldtx_Workspace_V4_AudioInputDevice] {
    store.definition.inputDevices.compactMap { input in
      guard case .audioDevice(let device)? = input.definition else { return nil }
      return device
    }
  }

  private func videoDeviceBinding(for internalID: UInt64) -> Binding<String> {
    Binding(
      get: { selectedVideoDeviceIDs[internalID] ?? "" },
      set: { id in
        selectedVideoDeviceIDs[internalID] = id
        guard let workspaceURL = session.url else { return }
        deviceMappingAppletData.setVideoDeviceID(
          id.isEmpty ? nil : id, for: internalID, workspaceURL: workspaceURL)
        synchronizeCaptureInputs()
      })
  }

  private func audioDeviceBinding(for internalID: UInt64) -> Binding<String> {
    Binding(
      get: { selectedAudioDeviceIDs[internalID] ?? "" },
      set: { id in
        selectedAudioDeviceIDs[internalID] = id
        guard let workspaceURL = session.url else { return }
        deviceMappingAppletData.setAudioDeviceID(
          id.isEmpty ? nil : id, for: internalID, workspaceURL: workspaceURL)
        synchronizeCaptureInputs()
        synchronizeAudioMonitor()
      })
  }

  private func refreshCaptureDevices() {
    let devices = session.availableCaptureDevices()
    cameras = devices.cameras
    audioDevices = devices.audioDevices
    guard let workspaceURL = session.url else {
      selectedVideoDeviceIDs = [:]
      selectedAudioDeviceIDs = [:]
      return
    }
    selectedVideoDeviceIDs = Dictionary(
      uniqueKeysWithValues: videoInputs.compactMap { input in
        deviceMappingAppletData.videoDeviceID(
          for: input.internalID, workspaceURL: workspaceURL
        ).map { (input.internalID, $0) }
      })
    selectedAudioDeviceIDs = Dictionary(
      uniqueKeysWithValues: audioInputs.compactMap { input in
        deviceMappingAppletData.audioDeviceID(
          for: input.internalID, workspaceURL: workspaceURL
        ).map { (input.internalID, $0) }
      })
    synchronizeCaptureInputs()
  }

  private func synchronizeCaptureInputs() {
    session.synchronizeCaptureInputs(availableCameraIDs: Set(cameras.map(\.id))) { failedIDs in
      guard !failedIDs.isEmpty else { return }
      Task { @MainActor in
        errorMessage =
          "Assigned camera(s) are unavailable: \(failedIDs.sorted().joined(separator: ", "))"
      }
    }
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
      if store.selectedProgramInternalID == nil,
        store.definition.programs.contains(where: {
          $0.internalID == id
        })
      {
        store.selectedProgramInternalID = id
      } else {
        session.updateRuntimes()
      }
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }
}
