// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
import SwiftUI

struct ProgramContentPane: View {
  @Binding var selectedSidebarItem: WorkspaceSidebarItem?
  var selectedProgramDefinitionName: String?
  @Binding var compositeProgramDefinition: CompositeProgramDefinition
  @Binding var portraitCompositeProgramDefinition: CompositeProgramDefinition
  var outputCanvas: OutputCanvasModel
  @Binding var previewSettings: AppPreviewSettings
  var workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  var lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  var programRuntime: ProgramRuntime
  var portraitProgramRuntime: ProgramRuntime
  var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
  @Binding var programPreferences: ProgramPreferences
  @Binding var portraitProgramPreferences: ProgramPreferences
  var activeProgramCanvasRole: Binding<ProgramCanvasRole> = .constant(.landscape)
  var workspaceInputDevices: [WorkspaceInputDeviceRecord]
  var workspaceVideoComponents: [WorkspaceVideoComponentRecord]
  var inputCameraDeviceMappings: [String: String]
  var audioPeakMeter: ProgramAudioPeakMeter
  var inputAudioPassthroughChannelKeys: Binding<Set<String>>
  var windowState = WorkspaceWindowState(
    mode: .edit,
    outputSessionState: .idle,
    isOperationLocked: false
  )
  @State private var isSyncEnabled = true

  var body: some View {
    VStack(spacing: 0) {
      CanvasPairPreview(
        landscapeRuntime: programRuntime, portraitRuntime: portraitProgramRuntime,
        landscapeSize: CGSize(
          width: outputCanvas.canvasSize.width, height: outputCanvas.canvasSize.height),
        portraitSize: CGSize(width: 1080, height: 1920)
      )
      .padding(.horizontal, 20)
      Form {
        Section {
          masterControl(
            "Landscape",
            symbol: "rectangle",
            value: outputMasterVolume, meter: .landscape)
          masterControl("Portrait", symbol: "rectangle.portrait", value: $portraitProgramPreferences.masterVolume, meter: .portrait)
            .disabled(isSyncEnabled)
          VStack(alignment: .leading, spacing: 4) {
            masterControl("Monitor", symbol: "headphones", value: $programPreferences.monitorVolume)
            MonitorOutputDevicePicker()
              .padding(.leading, 28)
          }
          ForEach(inputChannels.indices, id: \.self) { index in
            let channel = inputChannels[index]
            let key = inputChannels.audioChannelKey(for: channel)
            VStack(spacing: 4) {
              HStack {
                Text(audioChannelLabel(for: channel))
                Spacer()
                connectionToggle(
                  "Landscape",
                  symbol: "rectangle",
                  channel: channel, portrait: false)
                connectionToggle(
                  "Portrait", symbol: "rectangle.portrait", channel: channel, portrait: true)
                  .disabled(isSyncEnabled)
                Toggle(isOn: inputAudioPassthroughBinding(for: key)) {
                  connectionIcon(
                    "headphones", isConnected: inputAudioPassthroughBinding(for: key).wrappedValue)
                }
                .toggleStyle(.button)
                .help("Monitor")
                .accessibilityLabel("Monitor " + audioChannelLabel(for: channel))
              }
              AudioChannelControl(
                label: "",
                value: programPreferences.audioChannelGain(for: channel, in: inputChannels),
                peakProvider: { audioPeakMeter.peak(for: key) },
                onPreview: { _ in },
                onCommit: { gain in
                  programPreferences.setAudioChannelGain(gain, for: channel, in: inputChannels)
                  portraitProgramPreferences.setAudioChannelGain(
                    gain, for: channel, in: inputChannels)
                })
            }
          }
        } header: {
          HStack {
            Text("Audio Mix")
            Spacer()
            Toggle("Sync", isOn: $isSyncEnabled)
              .toggleStyle(.switch)
          }
        }
      }
      .formStyle(.grouped)
    }
    .onAppear { applyCurrentVideoLayerPreferences() }
  }

  private var inputChannels: [ProgramAudioChannel] {
    compositeProgramDefinition.audioChannels.filter {
      if case .inputAudioDevice = $0.component { return true }
      return false
    }
  }

  private var outputMasterVolume: Binding<Double> {
    Binding(
      get: { programPreferences.masterVolume },
      set: { value in
        programPreferences.masterVolume = value
        if isSyncEnabled { portraitProgramPreferences.masterVolume = value }
      })
  }

  private func masterControl(
    _ name: String, symbol: String, value: Binding<Double>, meter: ProgramAudioPeakMeter.Master? = nil
  ) -> some View {
    HStack(spacing: 8) {
      Image(systemName: symbol)
        .frame(width: 20)
        .accessibilityHidden(true)
      AudioChannelControl(
        label: "", value: value.wrappedValue, peakProvider: meter.map { bus in { audioPeakMeter.peak(for: bus) } },
        onPreview: { value.wrappedValue = $0 }, onCommit: { _ in })
        .accessibilityLabel(name + " Master Volume")
    }
    .help(name + " Master Volume")
  }

  private func connectionToggle(
    _ name: String, symbol: String, channel: ProgramAudioChannel, portrait: Bool
  ) -> some View {
    let isConnected = Binding(
        get: {
          guard let id = inputAudioDeviceID(for: channel) else { return false }
          return !(portrait ? portraitProgramPreferences : programPreferences).isAudioMuted(
            inputDeviceName: id)
        },
        set: { connected in
          guard let id = inputAudioDeviceID(for: channel) else { return }
          if portrait {
            portraitProgramPreferences.setAudioMuted(!connected, inputDeviceName: id)
          } else {
            programPreferences.setAudioMuted(!connected, inputDeviceName: id)
          }
          if isSyncEnabled {
            portraitProgramPreferences.setAudioMuted(!connected, inputDeviceName: id)
          }
        })
    return Toggle(isOn: isConnected) {
      connectionIcon(symbol, isConnected: isConnected.wrappedValue)
    }
    .toggleStyle(.button)
    .help(name)
    .accessibilityLabel(name + " " + audioChannelLabel(for: channel))
  }

  private func connectionIcon(_ symbol: String, isConnected: Bool) -> some View {
    Image(systemName: symbol)
      .frame(width: 20, height: 16)
      .overlay {
        Capsule()
          .frame(width: 22, height: 1.5)
          .rotationEffect(.degrees(45))
          .opacity(isConnected ? 0 : 1)
          .allowsHitTesting(false)
      }
      .accessibilityHidden(true)
  }

  private func applyCurrentVideoLayerPreferences() {
    let programName =
      selectedProgramDefinitionName ?? selectedProgramDefinitionRecord?.name ?? "New Program"
    if activeProgramCanvasRole.wrappedValue == .portrait {
      portraitCompositeProgramDefinition = WorkspaceVideoComponentResolver.applying(
        workspaceVideoComponents,
        layers: portraitProgramPreferences.videoLayers(forProgramNamed: programName),
        to: portraitCompositeProgramDefinition,
        coordinateWidth: 1_080,
        coordinateHeight: 1_920)
    } else {
      compositeProgramDefinition = WorkspaceVideoComponentResolver.applying(
        workspaceVideoComponents,
        layers: programPreferences.videoLayers(forProgramNamed: programName),
        to: compositeProgramDefinition,
        coordinateWidth: 1_920,
        coordinateHeight: 1_080)
    }
  }

  private var activeAudioChannels: [ProgramAudioChannel] {
    activeProgramCanvasRole.wrappedValue == .portrait
      ? portraitCompositeProgramDefinition.audioChannels
      : compositeProgramDefinition.audioChannels
  }

  private func audioChannelLabel(for channel: ProgramAudioChannel) -> String {
    if case .inputAudioDevice(let payload) = channel.component,
      let inputDeviceID = payload.inputDeviceID,
      let inputDevice = workspaceInputDevices.first(where: { $0.id == inputDeviceID })
    {
      return inputDevice.name
    }
    return activeAudioChannels.audioChannelDisplayName(for: channel)
  }

  private func inputAudioDeviceID(for channel: ProgramAudioChannel) -> String? {
    guard case .inputAudioDevice(let payload) = channel.component else { return nil }
    return payload.inputDeviceID
  }

  private func inputAudioPassthroughBinding(for channelKey: String) -> Binding<Bool> {
    let selectionKey = channelKey
    return Binding(
      get: {
        inputAudioPassthroughChannelKeys.wrappedValue.contains(selectionKey)
      },
      set: { isEnabled in
        var channelKeys = inputAudioPassthroughChannelKeys.wrappedValue
        if isEnabled {
          channelKeys.insert(selectionKey)
        } else {
          channelKeys.remove(selectionKey)
        }
        inputAudioPassthroughChannelKeys.wrappedValue = channelKeys
      }
    )
  }

}
