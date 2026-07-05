// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import SwiftUI

struct ProgramContentPane: View {
    @Binding var mainWindowState: MainWindowState
    var programCameraInputSource: ProgramCameraInputSource
    var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
    var compositeProgramDefinition: CompositeProgramDefinition
    @Binding var programArguments: ProgramArguments
    var workspaceInputDevices: [WorkspaceInputDeviceRecord]
    var inputCameraDeviceMappings: [String: String]
    var audioPeakMeter: ProgramAudioPeakMeter
    var updateProgramAudioGains: (ProgramArguments) -> Void
    @State private var isShowingProgramArgumentsJSON = false

    var body: some View {
        Form {
            Section {
                ProgramPreviewPane(
                    mainWindowState: $mainWindowState,
                    programCameraInputSource: programCameraInputSource,
                    selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
                    compositeProgramDefinition: compositeProgramDefinition,
                    workspaceInputDevices: workspaceInputDevices,
                    inputCameraDeviceMappings: inputCameraDeviceMappings
                )
            }

            if !compositeProgramDefinition.audioChannels.isEmpty {
                Section("Audio Channels") {
                    ForEach(compositeProgramDefinition.audioChannels.indices, id: \.self) { index in
                        let channel = compositeProgramDefinition.audioChannels[index]
                        let channelKey = compositeProgramDefinition.audioChannelKey(for: channel)
                        AudioChannelControl(
                            label: channelKey,
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
                    }

                    HStack {
                        Spacer()

                        Button {
                            isShowingProgramArgumentsJSON = true
                        } label: {
                            Label("Arguments JSON", systemImage: "curlybraces")
                        }
                        .accessibilityIdentifier("showProgramArgumentsJSONButton")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingProgramArgumentsJSON) {
            ProgramArgumentsJSONView(jsonText: programArgumentsJSONText)
        }
    }

    private func audioChannelGain(for channel: ProgramAudioChannel) -> Double {
        programArguments.audioChannelGain(for: channel, in: compositeProgramDefinition)
    }

    private func previewAudioChannelGain(_ gain: Double, for channel: ProgramAudioChannel) {
        var previewArguments = programArguments
        previewArguments.setAudioChannelGain(
            gain,
            for: channel,
            in: compositeProgramDefinition
        )
        updateProgramAudioGains(previewArguments)
    }

    private func commitAudioChannelGain(_ gain: Double, for channel: ProgramAudioChannel) {
        programArguments.setAudioChannelGain(
            gain,
            for: channel,
            in: compositeProgramDefinition
        )
    }

    private var programArgumentsJSONText: String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(programArguments)
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
