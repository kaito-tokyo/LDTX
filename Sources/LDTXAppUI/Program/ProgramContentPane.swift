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
    var outputDestination: OutputDestinationModel
    var workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator
    var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
    @Binding var programArguments: ProgramArguments
    var workspaceInputDevices: [WorkspaceInputDeviceRecord]
    var inputCameraDeviceMappings: [String: String]
    var audioPeakMeter: ProgramAudioPeakMeter
    var updateProgramAudioGains: (ProgramArguments) -> Void
    @State private var isShowingProgramArgumentsJSON = false
    @State private var isShowingProgramDefinitionJSON = false
    @State var draggedVideoComponentID: UUID?

    var body: some View {
        Form {
            Section {
                ProgramPreviewPane(
                    outputCanvas: outputCanvas,
                    outputDestination: outputDestination,
                    workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
                    selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
                    compositeProgramDefinition: compositeProgramDefinition,
                    workspaceInputDevices: workspaceInputDevices,
                    inputCameraDeviceMappings: inputCameraDeviceMappings
                )
            }

            Section("Video Components") {
                videoComponentControls
            }

            Section("Audio Channel Definitions") {
                audioChannelDefinitionControls
            }

            if !compositeProgramDefinition.audioChannels.isEmpty {
                Section("Audio Mix") {
                    ForEach(compositeProgramDefinition.audioChannels.indices, id: \.self) { index in
                        let channel = compositeProgramDefinition.audioChannels[index]
                        let channelKey = compositeProgramDefinition.audioChannelKey(for: channel)
                        AudioChannelControl(
                            label: compositeProgramDefinition.audioChannelDisplayName(for: channel),
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

                    Button {
                        isShowingProgramArgumentsJSON = true
                    } label: {
                        Label("Arguments JSON", systemImage: "curlybraces")
                    }
                    .accessibilityIdentifier("showProgramArgumentsJSONButton")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingProgramArgumentsJSON) {
            ProgramArgumentsJSONView(jsonText: programArgumentsJSONText)
        }
        .sheet(isPresented: $isShowingProgramDefinitionJSON) {
            ProgramDefinitionJSONView(jsonText: programDefinitionJSONText)
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

    private var currentProgramDefinitionRecord: SavedProgramDefinitionRecord {
        SavedProgramDefinitionRecord(
            name: selectedProgramDefinitionRecord?.name ?? selectedProgramDefinitionName ?? "New Program",
            canvasWidth: outputCanvas.canvasSize.width,
            canvasHeight: outputCanvas.canvasSize.height,
            frameRateNumerator: max(outputCanvas.programDefinitionFrameRate, 1),
            frameRateDenominator: 1,
            composite: outputCanvas.applying(to: compositeProgramDefinition)
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
    @State private var compositeProgramDefinition = LDTXAppUIPreviewFixtures.compositeProgramDefinition
    @State private var outputCanvas = LDTXAppUIPreviewFixtures.makeOutputCanvasModel()
    @State private var outputDestination = LDTXAppUIPreviewFixtures.makeOutputDestinationModel()
    @State private var programArguments = LDTXAppUIPreviewFixtures.programArguments

    var body: some View {
        ProgramContentPane(
            selectedSidebarItem: .constant(nil),
            selectedProgramDefinitionName: LDTXAppUIPreviewFixtures.selectedProgramDefinitionName,
            compositeProgramDefinition: $compositeProgramDefinition,
            outputCanvas: outputCanvas,
            outputDestination: outputDestination,
            workspaceCaptureSessionCoordinator: LDTXAppUIPreviewFixtures.makeWorkspaceCaptureSessionCoordinator(),
            selectedProgramDefinitionRecord: LDTXAppUIPreviewFixtures.selectedProgramDefinitionRecord,
            programArguments: $programArguments,
            workspaceInputDevices: LDTXAppUIPreviewFixtures.workspaceInputDevices,
            inputCameraDeviceMappings: LDTXAppUIPreviewFixtures.inputCameraDeviceMappings,
            audioPeakMeter: LDTXAppUIPreviewFixtures.makeAudioPeakMeter(),
            updateProgramAudioGains: { programArguments = $0 }
        )
    }
}
#endif
