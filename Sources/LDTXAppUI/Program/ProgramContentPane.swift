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
  var outputCanvas: OutputCanvasModel
  @Binding var previewSettings: AppPreviewSettings
  var workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  var lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  var programRuntime: ProgramRuntime
  var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
  @Binding var programPreferences: ProgramPreferences
  var workspaceInputDevices: [WorkspaceInputDeviceRecord]
  var workspaceVideoComponents: [WorkspaceVideoComponentRecord]
  var workspaceAudioChannels: [ProgramAudioChannel]
  var inputCameraDeviceMappings: [String: String]
  var audioPeakMeter: ProgramAudioPeakMeter
  var inputAudioPassthroughChannelKeys: Binding<Set<String>>
  var updateProgramAudioGains: (ProgramPreferences) -> Void
  var windowState = WorkspaceWindowState(
    mode: .edit,
    outputSessionState: .idle,
    isOperationLocked: false
  )
  @State private var isShowingProgramPreferencesJSON = false
  @State private var isShowingProgramDefinitionJSON = false

  var body: some View {
    Form {
      Section {
        ProgramPreviewPane(
          outputCanvas: outputCanvas,
          previewSettings: $previewSettings,
          workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
          lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
          programRuntime: programRuntime,
          selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
          compositeProgramDefinition: compositeProgramDefinition,
          workspaceInputDevices: workspaceInputDevices,
          workspaceAudioChannels: effectiveWorkspaceAudioChannels,
          inputCameraDeviceMappings: inputCameraDeviceMappings
        )
      }

      if !effectiveWorkspaceAudioChannels.isEmpty {
        Section("Audio Mix") {
          ForEach(effectiveWorkspaceAudioChannels.indices, id: \.self) { index in
            let channel = effectiveWorkspaceAudioChannels[index]
            let channelKey = effectiveWorkspaceAudioChannels.audioChannelKey(for: channel)
            HStack(spacing: 8) {
              AudioChannelControl(
                label: audioChannelLabel(for: channel),
                value: audioChannelGain(for: channel),
                peakProvider: {
                  audioPeakMeter.peak(for: channelKey)
                },
                onPreview: { gain in
                  previewAudioChannelGain(gain, for: channel)
                },
                onCommit: { gain in
                  commitAudioChannelGain(gain, for: channel)
                }
              )

              if isInputAudioDeviceChannel(channel) {
                Button {
                  toggleAudioMute(for: channel)
                } label: {
                  Image(
                    systemName: isAudioMuted(for: channel)
                      ? "speaker.slash.fill" : "speaker.wave.2.fill"
                  )
                }
                .buttonStyle(.borderless)
                .help(
                  isAudioMuted(for: channel)
                    ? "Unmute \(audioChannelLabel(for: channel))"
                    : "Mute \(audioChannelLabel(for: channel))"
                )
                .accessibilityLabel(
                  isAudioMuted(for: channel) ? "Unmute audio" : "Mute audio"
                )

                Toggle(
                  "",
                  isOn: inputAudioPassthroughBinding(for: channelKey)
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .help("Play \(audioChannelLabel(for: channel)) through this app")
              }
            }
          }
        }
      }

      Section {
        HStack {
          Spacer()

          Button {
            isShowingProgramDefinitionJSON = true
          } label: {
            Label("Program JSON", systemImage: "curlybraces")
          }
          .accessibilityIdentifier("showProgramDefinitionJSONButton")
          .disabled(windowState.mode != .edit || windowState.isOperationLocked)

          Button {
            isShowingProgramPreferencesJSON = true
          } label: {
            Label("Preferences JSON", systemImage: "curlybraces")
          }
          .accessibilityIdentifier("showProgramPreferencesJSONButton")
        }
      }
    }
    .formStyle(.grouped)
    .sheet(isPresented: $isShowingProgramPreferencesJSON) {
      ProgramPreferencesJSONView(jsonText: programPreferencesJSONText)
    }
    .sheet(isPresented: $isShowingProgramDefinitionJSON) {
      ProgramDefinitionJSONView(jsonText: programDefinitionJSONText)
    }
    .onAppear { applyCurrentVideoLayerPreferences() }
  }

  private func applyCurrentVideoLayerPreferences() {
    compositeProgramDefinition = WorkspaceVideoComponentResolver.applying(
      workspaceVideoComponents,
      layers: programPreferences.videoLayers(
        forProgramNamed: selectedProgramDefinitionName
          ?? selectedProgramDefinitionRecord?.name
          ?? "New Program"
      ),
      to: compositeProgramDefinition
    )
  }

  private var effectiveWorkspaceAudioChannels: [ProgramAudioChannel] {
    workspaceInputDevices.resolvedWorkspaceAudioChannels(from: workspaceAudioChannels)
  }

  private func audioChannelGain(for channel: ProgramAudioChannel) -> Double {
    programPreferences.audioChannelGain(for: channel, in: effectiveWorkspaceAudioChannels)
  }

  private func previewAudioChannelGain(_ gain: Double, for channel: ProgramAudioChannel) {
    var previewPreferences = programPreferences
    previewPreferences.setAudioChannelGain(
      gain,
      for: channel,
      in: effectiveWorkspaceAudioChannels
    )
    updateProgramAudioGains(previewPreferences)
  }

  private func commitAudioChannelGain(_ gain: Double, for channel: ProgramAudioChannel) {
    programPreferences.setAudioChannelGain(
      gain,
      for: channel,
      in: effectiveWorkspaceAudioChannels
    )
  }

  private func audioChannelLabel(for channel: ProgramAudioChannel) -> String {
    if case .inputAudioDevice(let payload) = channel.component,
      let inputDeviceID = payload.inputDeviceID,
      let inputDevice = workspaceInputDevices.first(where: { $0.id == inputDeviceID })
    {
      return inputDevice.name
    }
    return effectiveWorkspaceAudioChannels.audioChannelDisplayName(for: channel)
  }

  private func isInputAudioDeviceChannel(_ channel: ProgramAudioChannel) -> Bool {
    if case .inputAudioDevice = channel.component {
      return true
    }
    return false
  }

  private func inputAudioDeviceID(for channel: ProgramAudioChannel) -> String? {
    guard case .inputAudioDevice(let payload) = channel.component else { return nil }
    return payload.inputDeviceID
  }

  private func isAudioMuted(for channel: ProgramAudioChannel) -> Bool {
    guard let inputDeviceID = inputAudioDeviceID(for: channel) else { return false }
    return programPreferences.isAudioMuted(inputDeviceName: inputDeviceID)
  }

  private func toggleAudioMute(for channel: ProgramAudioChannel) {
    guard let inputDeviceID = inputAudioDeviceID(for: channel) else { return }
    programPreferences.setAudioMuted(
      !programPreferences.isAudioMuted(inputDeviceName: inputDeviceID),
      inputDeviceName: inputDeviceID
    )
    updateProgramAudioGains(programPreferences)
  }

  private func inputAudioPassthroughBinding(for channelKey: String) -> Binding<Bool> {
    Binding(
      get: {
        inputAudioPassthroughChannelKeys.wrappedValue.contains(channelKey)
      },
      set: { isEnabled in
        var channelKeys = inputAudioPassthroughChannelKeys.wrappedValue
        if isEnabled {
          channelKeys.insert(channelKey)
        } else {
          channelKeys.remove(channelKey)
        }
        inputAudioPassthroughChannelKeys.wrappedValue = channelKeys
      }
    )
  }

  private var programPreferencesJSONText: String {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(programPreferences)
      return String(data: data, encoding: .utf8) ?? "{}"
    } catch {
      return """
        {
          "error" : "\(diagnosticDescription(error))"
        }
        """
    }
  }

  private var currentProgramDefinitionRecord: SavedProgramDefinitionRecord {
    SavedProgramDefinitionRecord(
      name: selectedProgramDefinitionRecord?.name ?? selectedProgramDefinitionName ?? "New Program",
      canvasWidth: outputCanvas.canvasSize.width,
      canvasHeight: outputCanvas.canvasSize.height,
      frameRateNumerator: max(outputCanvas.programDefinitionFrameRate, 1),
      frameRateDenominator: 1,
      composite: outputCanvas.applying(to: compositeProgramDefinition),
      inputDevices: []
    )
  }

  private var programDefinitionJSONText: String {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(currentProgramDefinitionRecord)
      return String(data: data, encoding: .utf8) ?? "{}"
    } catch {
      return """
        {
          "error" : "\(diagnosticDescription(error))"
        }
        """
    }
  }

  private func diagnosticDescription(_ error: Error) -> String {
    String(describing: error)
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
  }
}

#if DEBUG
  #Preview("Program Content") {
    ProgramContentPanePreviewHost()
      .frame(width: 560, height: 620)
  }

  private struct ProgramContentPanePreviewHost: View {
    @State private var compositeProgramDefinition = LDTXAppUIPreviewFixtures
      .compositeProgramDefinition
    @State private var outputCanvas = LDTXAppUIPreviewFixtures.makeOutputCanvasModel()
    @State private var previewSettings = LDTXAppUIPreviewFixtures.makeAppPreviewSettings()
    @State private var programPreferences = LDTXAppUIPreviewFixtures.programPreferences
    private let workspaceCaptureSessionCoordinator =
      LDTXAppUIPreviewFixtures.makeWorkspaceCaptureSessionCoordinator()
    private let lowFrequencyUpdateRegistry = LowFrequencyUpdateRegistry()

    private var previewRuntime: ProgramRuntime {
      LDTXAppUIPreviewFixtures.makeProgramRuntime(
        coordinator: workspaceCaptureSessionCoordinator,
        lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry
      )
    }

    var body: some View {
      ProgramContentPane(
        selectedSidebarItem: .constant(nil),
        selectedProgramDefinitionName: LDTXAppUIPreviewFixtures.selectedProgramDefinitionName,
        compositeProgramDefinition: $compositeProgramDefinition,
        outputCanvas: outputCanvas,
        previewSettings: $previewSettings,
        workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
        lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
        programRuntime: previewRuntime,
        selectedProgramDefinitionRecord: LDTXAppUIPreviewFixtures.selectedProgramDefinitionRecord,
        programPreferences: $programPreferences,
        workspaceInputDevices: LDTXAppUIPreviewFixtures.workspaceInputDevices,
        workspaceVideoComponents: [],
        workspaceAudioChannels: LDTXAppUIPreviewFixtures.workspaceAudioChannels,
        inputCameraDeviceMappings: LDTXAppUIPreviewFixtures.inputCameraDeviceMappings,
        audioPeakMeter: LDTXAppUIPreviewFixtures.makeAudioPeakMeter(),
        inputAudioPassthroughChannelKeys: .constant([]),
        updateProgramAudioGains: { programPreferences = $0 }
      )
    }
  }
#endif
