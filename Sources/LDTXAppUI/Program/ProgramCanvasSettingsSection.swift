// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct ProgramCanvasSettingsSection: View {
    var outputCanvas: OutputCanvasModel
    var windowState = WorkspaceWindowState(
        mode: .edit,
        outputSessionState: .idle,
        isOperationLocked: false
    )

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
        }
        .disabled(windowState.mode != .edit || windowState.isOperationLocked)
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
                outputCanvas: outputCanvas,
                windowState: WorkspaceWindowState(
                    mode: .edit,
                    outputSessionState: .idle,
                    isOperationLocked: false
                )
            )
        }
        .formStyle(.grouped)
    }
}
#endif
