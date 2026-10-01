// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXDeviceRegistry
import LDTXWorkspaceAppletInterface
import SwiftUI
import UniformTypeIdentifiers

public struct WorkspaceContent: View {
  @Environment(\.workspaceDispatcher) private var workspaceDispatcher
  let workspaceURL: URL
  let deviceRegistry: DeviceRegistryService
  @Bindable var uiState: WorkspaceUIState
  @Bindable var appletData: WorkspaceAppletData
  @State private var errorMessage: String?

  public init(
    workspaceURL: URL,
    deviceRegistry: DeviceRegistryService,
    uiState: WorkspaceUIState,
    appletData: WorkspaceAppletData
  ) {
    self.workspaceURL = workspaceURL
    self.deviceRegistry = deviceRegistry
    self._uiState = Bindable(wrappedValue: uiState)
    self._appletData = Bindable(wrappedValue: appletData)
  }

  public var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 16) {
        Text(uiState.definition.displayName)
          .font(.title2.weight(.semibold))
        HStack {
          Button("Add Program") { addProgram() }.disabled(uiState.isOutputActive)
          Button("Add Video Input") { addVideoInput() }.disabled(uiState.isOutputActive)
          Button("Add Audio Input") { addAudioInput() }.disabled(uiState.isOutputActive)
          Button("Add VFX Source") { addVFXSource() }
            .disabled(firstVideoInputID == nil || uiState.isOutputActive)
          Menu("Add Video Component") {
            Button("Solid Color") { addSolidColor() }
            Button("Linear Gradient") { addLinearGradient() }
            Button("Radial Gradient") { addRadialGradient() }
            Button("Conic Gradient") { addConicGradient() }
            Divider()
            Button("Clock") { addClock() }
            Button("Test Pattern") { addTestPattern() }
          }
          .disabled(uiState.isOutputActive)
          Button("Add OCR Vision") { addOcrVision() }
            .disabled(firstVideoInputID == nil || uiState.isOutputActive)
          Button(uiState.isOutputActive ? "Stop Output" : "Start Output") {
            Task {
              guard let workspaceDispatcher else {
                errorMessage = "Workspace output is unavailable."
                return
              }
              if uiState.isOutputActive {
                await workspaceDispatcher.stopOutput()
              } else {
                do {
                  try await workspaceDispatcher.startOutput()
                } catch {
                  errorMessage = error.localizedDescription
                }
              }
            }
          }
          if uiState.isOutputActive && uiState.isLocalRecording {
            Button("Capture Screenshot(s)") {
              do { _ = try workspaceDispatcher?.captureScreenshots() } catch {
                errorMessage = error.localizedDescription
              }
            }
            Button("Open Screenshots Folder") {
              workspaceDispatcher?.openScreenshotsDirectory()
            }
          }
        }
        videoLayers
        audioMix
        inputDeviceAssignments
        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        if let message = uiState.outputFailureMessage {
          Text(message).foregroundStyle(.red)
        }
        Spacer()
      }
      .padding(20)
    }
    .onAppear {
      refreshCaptureDevices()
      workspaceDispatcher?.synchronizeAudioMonitor()
    }
  }

  private func addProgram() {
    let id = nextInternalID()
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = id
    program.displayName = uniqueProgramDisplayName("Program")
    var definition = uiState.definition
    definition.programs.append(program)
    uiState.definition = definition
    if localState.selectedProgramInternalID == nil {
      var state = localState
      state.selectedProgramInternalID = id
      setLocalState(state)
    }
    errorMessage = nil
    workspaceDispatcher?.synchronizeAudioMonitor()
  }
  private func addVideoInput() {
    let id = nextInternalID()
    var device = Ldtx_Workspace_V4_VideoInputDevice()
    device.internalID = id
    device.displayName = uniqueDisplayName("Video Input")
    var wrapper = Ldtx_Workspace_V4_InputDeviceWrapper()
    wrapper.videoDevice = device
    var definition = uiState.definition
    definition.inputDevices.append(wrapper)
    uiState.definition = definition
    errorMessage = nil
  }
  private func addAudioInput() {
    let id = nextInternalID()
    var device = Ldtx_Workspace_V4_AudioInputDevice()
    device.internalID = id
    device.displayName = uniqueDisplayName("Audio Input")
    var wrapper = Ldtx_Workspace_V4_InputDeviceWrapper()
    wrapper.audioDevice = device
    var definition = uiState.definition
    definition.inputDevices.append(wrapper)
    uiState.definition = definition
    workspaceDispatcher?.synchronizeAudioMonitor()
  }
  private func addVFXSource() {
    guard let inputID = firstVideoInputID else { return }
    var component = Ldtx_Workspace_V4_VfxSourceComponent()
    component.internalID = nextInternalID()
    component.displayName = uniqueDisplayName("VFX Source")
    component.inputDeviceInternalID = inputID
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.vfxSource = component
    appendVideoComponent(wrapper)
  }

  private func addSolidColor() {
    var color = Ldtx_Workspace_V4_ExtendedSrgbColor()
    color.red = 0.2
    color.green = 0.2
    color.blue = 0.2
    color.alpha = 1
    var component = Ldtx_Workspace_V4_FillSolidColorComponent()
    component.internalID = nextInternalID()
    component.displayName = uniqueDisplayName("Solid Color")
    component.color = color
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.solidColorFill = component
    appendVideoComponent(wrapper)
  }

  private func addClock() {
    var component = Ldtx_Workspace_V4_ClockComponent()
    component.internalID = nextInternalID()
    component.displayName = uniqueDisplayName("Clock")
    component.width = 320 / 1_920
    component.height = 80 / 1_080
    component.foregroundColor = opaqueWhite
    var background = Ldtx_Workspace_V4_ExtendedSrgbColor()
    background.alpha = 0.65
    component.backgroundColor = background
    component.showsSeconds = true
    component.uses24HourTime = true
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.clock = component
    appendVideoComponent(wrapper)
  }

  private func addLinearGradient() {
    var component = Ldtx_Workspace_V4_FillLinearGradientComponent()
    component.internalID = nextInternalID()
    component.displayName = uniqueDisplayName("Linear Gradient")
    component.startColor = gradientStartColor
    component.endX = 1
    component.endY = 1
    component.endColor = gradientEndColor
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.linearGradientFill = component
    appendVideoComponent(wrapper)
  }

  private func addRadialGradient() {
    var component = Ldtx_Workspace_V4_FillRadialGradientComponent()
    component.internalID = nextInternalID()
    component.displayName = uniqueDisplayName("Radial Gradient")
    component.centerX = 0.5
    component.centerY = 0.5
    component.outerRadius = 0.5
    component.innerColor = gradientStartColor
    component.outerColor = gradientEndColor
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.radialGradientFill = component
    appendVideoComponent(wrapper)
  }

  private func addConicGradient() {
    var component = Ldtx_Workspace_V4_FillConicGradientComponent()
    component.internalID = nextInternalID()
    component.displayName = uniqueDisplayName("Conic Gradient")
    component.centerX = 0.5
    component.centerY = 0.5
    component.startColor = gradientStartColor
    component.endColor = gradientEndColor
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.conicGradientFill = component
    appendVideoComponent(wrapper)
  }

  private func addTestPattern() {
    var component = Ldtx_Workspace_V4_TestPatternComponent()
    component.internalID = nextInternalID()
    component.displayName = uniqueDisplayName("Test Pattern")
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.testPattern = component
    appendVideoComponent(wrapper)
  }

  private func addOcrVision() {
    guard let inputID = firstVideoInputID else { return }
    var trigger = Ldtx_Workspace_V4_IntervalVisionTrigger()
    trigger.intervalSeconds = 5
    var triggerWrapper = Ldtx_Workspace_V4_VisionTriggerWrapper()
    triggerWrapper.intervalTrigger = trigger
    var vision = Ldtx_Workspace_V4_OcrVision()
    vision.internalID = nextInternalID()
    vision.displayName = uniqueDisplayName("OCR Vision")
    vision.inputDeviceInternalID = inputID
    vision.source = .inputDeviceInternalID(inputID)
    vision.triggers = [triggerWrapper]
    var wrapper = Ldtx_Workspace_V4_VisionWrapper()
    wrapper.ocrVision = vision
    var definition = uiState.definition
    definition.visions.append(wrapper)
    uiState.definition = definition
    errorMessage = nil
    workspaceDispatcher?.synchronizeVision()
  }

  private func appendVideoComponent(_ wrapper: Ldtx_Workspace_V4_VideoComponentWrapper) {
    var definition = uiState.definition
    definition.videoComponents.append(wrapper)
    uiState.definition = definition
    if let id = componentInternalID(wrapper) { addToSelectedProgram(id) }
    errorMessage = nil
  }

  private var gradientStartColor: Ldtx_Workspace_V4_ExtendedSrgbColor {
    var color = Ldtx_Workspace_V4_ExtendedSrgbColor()
    color.red = 1
    color.green = 1
    color.blue = 1
    color.alpha = 1
    return color
  }

  private var gradientEndColor: Ldtx_Workspace_V4_ExtendedSrgbColor {
    var color = Ldtx_Workspace_V4_ExtendedSrgbColor()
    color.red = 0.15
    color.green = 0.35
    color.blue = 0.85
    color.alpha = 1
    return color
  }

  private var opaqueWhite: Ldtx_Workspace_V4_ExtendedSrgbColor { gradientStartColor }

  private func nextInternalID() -> UInt64 {
    let milliseconds = UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
    return ((milliseconds & 0x0000_FFFF_FFFF_FFFF) << 15)
      | UInt64.random(in: 0...0x7fff)
  }

  private func addToSelectedProgram(_ videoLayerInternalID: UInt64) {
    guard let programID = localState.selectedProgramInternalID else { return }
    for role in ProgramCanvasRole.allCases {
      let existing =
        uiState.definition.programs.first {
          $0.internalID == programID
        }.map {
          role == .landscape ? $0.landscapeVideoLayerInternalIds : $0.portraitVideoLayerInternalIds
        }
        ?? []
      performLayerOrderUpdate(existing + [videoLayerInternalID], for: programID, role: role)
    }
  }

  private func uniqueDisplayName(_ base: String) -> String {
    let definition = uiState.definition
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
    let names = Set(uiState.definition.programs.map(\.displayName))
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
          uiState.isOutputActive
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
            .disabled(uiState.isOutputActive || index == 0)
            Button {
              moveVideoLayer(in: program, role: role, from: index, offset: 1)
            } label: {
              Image(systemName: "arrow.down")
            }
            .disabled(uiState.isOutputActive || index == layerIDs.count - 1)
            Button {
              removeVideoLayer(in: program, role: role, at: index)
            } label: {
              Image(systemName: "minus")
            }
            .accessibilityLabel("Remove \(videoLayerDisplayName(for: internalID)) from \(title)")
            .disabled(uiState.isOutputActive)
          }
          WorkspaceV4LayerTransformEditor(
            uiState: uiState, programInternalID: program.internalID,
            role: role, videoLayerInternalID: internalID)
        }
      }
    }
  }

  private var selectedProgram: Ldtx_Workspace_V4_ProgramDefinition? {
    guard
      let id = localState.selectedProgramInternalID ?? uiState.definition.programs.first?.internalID
    else { return nil }
    return uiState.definition.programs.first { $0.internalID == id }
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
              get: {
                localState.synchronizesLandscapeMixToPortraitByProgramInternalID[
                  selectedProgram.internalID] ?? false
              },
              set: {
                var state = localState
                state.synchronizesLandscapeMixToPortraitByProgramInternalID[
                  selectedProgram.internalID] = $0
                setLocalState(state)
                workspaceDispatcher?.updateMixPreferences()
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
        let preference = uiState.preferences.programPreferences[
          programInternalID]
        return role == .landscape
          ? preference?.landscapeMasterVolume ?? 0 : preference?.portraitMasterVolume ?? 0
      },
      set: { value in
        var preferences = uiState.preferences
        var preference = preferences.programPreferences[programInternalID] ?? .init()
        switch role {
        case .landscape: preference.landscapeMasterVolume = value
        case .portrait: preference.portraitMasterVolume = value
        }
        preferences.programPreferences[programInternalID] = preference
        uiState.preferences = preferences
        workspaceDispatcher?.updateMixPreferences()
        workspaceDispatcher?.synchronizeAudioMonitor()
      })
  }

  private func audioGainBinding(
    for inputDeviceInternalID: UInt64,
    programInternalID: UInt64,
    role: ProgramCanvasRole
  ) -> Binding<Double> {
    Binding(
      get: {
        let preference = uiState.preferences.programPreferences[
          programInternalID]
        return role == .landscape
          ? preference?.landscapeAudioChannelGains[inputDeviceInternalID] ?? 0
          : preference?.portraitAudioChannelGains[inputDeviceInternalID] ?? 0
      },
      set: { value in
        var preferences = uiState.preferences
        var preference = preferences.programPreferences[programInternalID] ?? .init()
        switch role {
        case .landscape: preference.landscapeAudioChannelGains[inputDeviceInternalID] = value
        case .portrait: preference.portraitAudioChannelGains[inputDeviceInternalID] = value
        }
        preferences.programPreferences[programInternalID] = preference
        uiState.preferences = preferences
        workspaceDispatcher?.updateMixPreferences()
        workspaceDispatcher?.synchronizeAudioMonitor()
      })
  }

  private func audioMuteBinding(
    for inputDeviceInternalID: UInt64,
    programInternalID: UInt64,
    role: ProgramCanvasRole
  ) -> Binding<Bool> {
    Binding(
      get: {
        let preference = uiState.preferences.programPreferences[
          programInternalID]
        return role == .landscape
          ? preference?.landscapeAudioChannelMuted[inputDeviceInternalID] ?? false
          : preference?.portraitAudioChannelMuted[inputDeviceInternalID] ?? false
      },
      set: { value in
        var preferences = uiState.preferences
        var preference = preferences.programPreferences[programInternalID] ?? .init()
        switch role {
        case .landscape: preference.landscapeAudioChannelMuted[inputDeviceInternalID] = value
        case .portrait: preference.portraitAudioChannelMuted[inputDeviceInternalID] = value
        }
        preferences.programPreferences[programInternalID] = preference
        uiState.preferences = preferences
        workspaceDispatcher?.updateMixPreferences()
        workspaceDispatcher?.synchronizeAudioMonitor()
      })
  }

  private var monitorVolumeBinding: Binding<Double> {
    Binding(
      get: { uiState.preferences.monitorVolume },
      set: { value in
        var preferences = uiState.preferences
        preferences.monitorVolume = value
        uiState.preferences = preferences
        workspaceDispatcher?.synchronizeAudioMonitor()
      })
  }

  private func monitorBinding(for inputDeviceInternalID: UInt64) -> Binding<Bool> {
    Binding(
      get: { localState.monitorAudioInputDeviceInternalIDs.contains(inputDeviceInternalID) },
      set: { enabled in
        appletData.updateState(for: workspaceURL) { state in
          if enabled {
            state.monitorAudioInputDeviceInternalIDs.insert(inputDeviceInternalID)
          } else {
            state.monitorAudioInputDeviceInternalIDs.remove(inputDeviceInternalID)
          }
        }
        workspaceDispatcher?.synchronizeAudioMonitor()
      })
  }

  private func moveVideoLayer(
    in program: Ldtx_Workspace_V4_ProgramDefinition,
    role: ProgramCanvasRole,
    from index: Int,
    offset: Int
  ) {
    guard !uiState.isOutputActive else { return }
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
    guard !uiState.isOutputActive else { return }
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
    let inputIDs = uiState.definition.inputDevices.compactMap {
      input -> UInt64? in
      guard case .videoDevice(let device)? = input.definition else { return nil }
      return device.internalID
    }
    let componentIDs = uiState.definition.videoComponents.compactMap {
      componentInternalID($0)
    }
    return (inputIDs + componentIDs).filter { !usedIDs.contains($0) }
  }

  private func addVideoLayer(
    _ internalID: UInt64,
    to program: Ldtx_Workspace_V4_ProgramDefinition,
    role: ProgramCanvasRole
  ) {
    guard !uiState.isOutputActive else { return }
    let existing =
      role == .landscape
      ? program.landscapeVideoLayerInternalIds : program.portraitVideoLayerInternalIds
    performLayerOrderUpdate(existing + [internalID], for: program.internalID, role: role)
  }

  private func performLayerOrderUpdate(
    _ layerIDs: [UInt64], for programInternalID: UInt64, role: ProgramCanvasRole
  ) {
    guard
      let index = uiState.definition.programs.firstIndex(where: {
        $0.internalID == programInternalID
      })
    else { return }
    var definition = uiState.definition
    switch role {
    case .landscape: definition.programs[index].landscapeVideoLayerInternalIds = layerIDs
    case .portrait: definition.programs[index].portraitVideoLayerInternalIds = layerIDs
    }
    uiState.definition = definition
    errorMessage = nil
  }

  private func videoLayerMuteBinding(
    layerInternalID: UInt64,
    programInternalID: UInt64,
    role: ProgramCanvasRole
  ) -> Binding<Bool> {
    Binding(
      get: {
        let preference = uiState.preferences.programPreferences[
          programInternalID]
        switch role {
        case .landscape: return preference?.landscapeVideoLayerMuted[layerInternalID] ?? false
        case .portrait: return preference?.portraitVideoLayerMuted[layerInternalID] ?? false
        }
      },
      set: { muted in
        var preferences = uiState.preferences
        var preference = preferences.programPreferences[programInternalID] ?? .init()
        switch role {
        case .landscape: preference.landscapeVideoLayerMuted[layerInternalID] = muted
        case .portrait: preference.portraitVideoLayerMuted[layerInternalID] = muted
        }
        preferences.programPreferences[programInternalID] = preference
        uiState.preferences = preferences
      }
    )
  }

  private func videoLayerDisplayName(for internalID: UInt64) -> String {
    if let input = uiState.definition.inputDevices.first(where: {
      input in
      switch input.definition {
      case .videoDevice(let device): device.internalID == internalID
      case .audioDevice, nil: false
      }
    }), case .videoDevice(let device)? = input.definition {
      return device.displayName
    }
    if let component = uiState.definition.videoComponents.first(where: {
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
    uiState.definition.inputDevices.compactMap { input -> UInt64? in
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
              Text("No camera").tag(Optional<WorkspacePhysicalDeviceID>.none)
              ForEach(deviceRegistry.cameras) { camera in
                Text(camera.name).tag(
                  Optional(WorkspacePhysicalDeviceID.avCaptureDevice(uniqueID: camera.id)))
              }
            }
          }
          ForEach(audioInputs, id: \.internalID) { input in
            Picker(input.displayName, selection: audioDeviceBinding(for: input.internalID)) {
              Text("No audio device").tag(Optional<WorkspacePhysicalDeviceID>.none)
              ForEach(deviceRegistry.audioInputDevices) { device in
                Text(device.name).tag(
                  Optional(WorkspacePhysicalDeviceID.coreAudioDevice(uid: device.id)))
              }
            }
            .disabled(uiState.isOutputActive)
          }
          Button("Refresh Physical Devices") { refreshCaptureDevices() }
        }
      }
    }
  }

  private var videoInputs: [Ldtx_Workspace_V4_VideoInputDevice] {
    uiState.definition.inputDevices.compactMap { input in
      guard case .videoDevice(let device)? = input.definition else { return nil }
      return device
    }
  }

  private var audioInputs: [Ldtx_Workspace_V4_AudioInputDevice] {
    uiState.definition.inputDevices.compactMap { input in
      guard case .audioDevice(let device)? = input.definition else { return nil }
      return device
    }
  }

  private func videoDeviceBinding(for internalID: UInt64) -> Binding<WorkspacePhysicalDeviceID?> {
    Binding(
      get: {
        guard
          case .avCaptureDevice? = appletData.state(for: workspaceURL)
            .physicalDeviceIDsByInputDeviceInternalID[internalID]
        else { return nil }
        return appletData.state(for: workspaceURL).physicalDeviceIDsByInputDeviceInternalID[
          internalID]
      },
      set: { id in
        appletData.updateState(for: workspaceURL) {
          $0.physicalDeviceIDsByInputDeviceInternalID[internalID] = id
        }
        workspaceDispatcher?.updateProgramRuntimes()
        synchronizeCaptureInputs()
      })
  }

  private func audioDeviceBinding(for internalID: UInt64) -> Binding<WorkspacePhysicalDeviceID?> {
    Binding(
      get: {
        guard
          case .coreAudioDevice? = appletData.state(for: workspaceURL)
            .physicalDeviceIDsByInputDeviceInternalID[internalID]
        else { return nil }
        return appletData.state(for: workspaceURL).physicalDeviceIDsByInputDeviceInternalID[
          internalID]
      },
      set: { id in
        appletData.updateState(for: workspaceURL) {
          $0.physicalDeviceIDsByInputDeviceInternalID[internalID] = id
        }
        workspaceDispatcher?.updateProgramRuntimes()
        synchronizeCaptureInputs()
        workspaceDispatcher?.synchronizeAudioMonitor()
      })
  }

  private func refreshCaptureDevices() {
    deviceRegistry.refresh()
    errorMessage = deviceRegistry.errorMessage
    synchronizeCaptureInputs()
  }

  private func synchronizeCaptureInputs() {
    workspaceDispatcher?.synchronizeCaptureInputs(
      availableCameraIDs: Set(deviceRegistry.cameras.map(\.id))
    ) { failedIDs in
      guard !failedIDs.isEmpty else { return }
      Task { @MainActor in
        errorMessage =
          "Assigned camera(s) are unavailable: \(failedIDs.sorted().joined(separator: ", "))"
      }
    }
  }

  private var localState: WorkspaceLocalState {
    appletData.state(for: workspaceURL)
  }

  private func setLocalState(_ state: WorkspaceLocalState) {
    appletData.setState(state, for: workspaceURL)
    workspaceDispatcher?.updateProgramRuntimes()
  }
}
