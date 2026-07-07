// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import SwiftUI

struct ProgramCanvasSettingsSection: View {
    var compositeProgramDefinition: CompositeProgramDefinition
    var outputCanvas: OutputCanvasModel

    var body: some View {
        @Bindable var outputCanvas = outputCanvas

        Section("Canvas Settings") {
            Picker("Canvas Size", selection: $outputCanvas.canvasSize) {
                ForEach(OutputCanvasModel.supportedCanvasSizes, id: \.self) { canvasSize in
                    Text(verbatim: canvasSizeLabel(width: canvasSize.width, height: canvasSize.height))
                        .tag(canvasSize)
                }
            }
            .pickerStyle(.menu)

            Picker("FPS", selection: $outputCanvas.programDefinitionFrameRate) {
                ForEach([60, 30], id: \.self) { frameRate in
                    Text(verbatim: frameRateOptionLabel(frameRate))
                        .tag(frameRate)
                }
            }
            .pickerStyle(.menu)

            Picker("Video PTS Source", selection: programVideoPTSInputBinding) {
                if programVideoPTSInputRows.isEmpty {
                    Text("Host Clock Fallback").tag(Optional<String>.none)
                }
                ForEach(programVideoPTSInputRows, id: \.key) { row in
                    Text(row.label).tag(Optional(row.key))
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var programVideoPTSInputRows: [(key: String, label: String)] {
        compositeProgramDefinition.steps.compactMap { step in
            guard step.component.definition.usesInputCameraDevice else {
                return nil
            }
            return (
                key: compositeProgramDefinition.inputCameraDeviceMappingKey(for: step),
                label: compositeProgramDefinition.inputCameraDeviceDisplayName(for: step)
            )
        }
    }

    private var programVideoPTSInputBinding: Binding<String?> {
        Binding(
            get: {
                if let key = outputCanvas.programVideoPTSInputKey,
                   programVideoPTSInputRows.contains(where: { $0.key == key }) {
                    return key
                }
                return programVideoPTSInputRows.first?.key
            },
            set: { key in
                outputCanvas.programVideoPTSInputKey = key ?? programVideoPTSInputRows.first?.key
            }
        )
    }

    private func canvasSizeLabel(width: Int, height: Int) -> String {
        let format = String(
            localized: "programDefinition.canvasSize.valueFormat",
            defaultValue: "%lldx%lld",
            comment: "Canvas size value displayed as width x height."
        )
        return String(format: format, Int64(width), Int64(height))
    }

    private func frameRateOptionLabel(_ frameRate: Int) -> String {
        let format = String(
            localized: "programDefinition.frameRate.optionFormat",
            defaultValue: "%lld",
            comment: "Frame rate picker option."
        )
        return String(format: format, Int64(frameRate))
    }
}

#if DEBUG
#Preview("Program Canvas Settings") {
    ProgramCanvasSettingsSectionPreviewHost()
        .frame(width: 420, height: 260)
}

private struct ProgramCanvasSettingsSectionPreviewHost: View {
    @State private var outputCanvas = LDTXAppUIPreviewFixtures.makeOutputCanvasModel()

    var body: some View {
        Form {
            ProgramCanvasSettingsSection(
                compositeProgramDefinition: LDTXAppUIPreviewFixtures.compositeProgramDefinition,
                outputCanvas: outputCanvas
            )
        }
        .formStyle(.grouped)
    }
}
#endif
