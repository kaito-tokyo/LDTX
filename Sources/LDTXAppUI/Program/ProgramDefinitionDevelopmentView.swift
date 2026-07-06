// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import SwiftUI

struct ProgramDefinitionDevelopmentView: View {
    @Binding var selectedProgramDefinitionName: String?
    @Binding var composite: CompositeProgramDefinition
    var outputCanvas: OutputCanvasModel
    @Binding var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?
    @Binding var workspaceInputDevices: [WorkspaceInputDeviceRecord]
    var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
    var reloadSavedProgramDefinitions: () -> Void
    var refreshCameras: () -> Void
    var saveProgramDefinitionRecord: (SavedProgramDefinitionRecord) -> Bool
    var programDefinitionDirtyChanged: (Bool) -> Void
    @State var isProgramDefinitionDirty = false
    @State var isApplyingSavedProgramDefinition = false
    @State private var isShowingProgramDefinitionJSON = false

    init(
        selectedProgramDefinitionName: Binding<String?>,
        compositeProgramDefinition: Binding<CompositeProgramDefinition>,
        outputCanvas: OutputCanvasModel,
        workspaceInputDevices: Binding<[WorkspaceInputDeviceRecord]>,
        selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?,
        reloadSavedProgramDefinitions: @escaping () -> Void,
        refreshCameras: @escaping () -> Void,
        saveProgramDefinitionRecord: @escaping (SavedProgramDefinitionRecord) -> Bool,
        programDefinitionDirtyChanged: @escaping (Bool) -> Void,
        saveProgramDefinitionCommand: Binding<ProgramDefinitionSaveCommand?>
    ) {
        _selectedProgramDefinitionName = selectedProgramDefinitionName
        _composite = compositeProgramDefinition
        self.outputCanvas = outputCanvas
        _saveProgramDefinitionCommand = saveProgramDefinitionCommand
        _workspaceInputDevices = workspaceInputDevices
        self.selectedProgramDefinitionRecord = selectedProgramDefinitionRecord
        self.reloadSavedProgramDefinitions = reloadSavedProgramDefinitions
        self.refreshCameras = refreshCameras
        self.saveProgramDefinitionRecord = saveProgramDefinitionRecord
        self.programDefinitionDirtyChanged = programDefinitionDirtyChanged
    }

    var body: some View {
        editorForm
            .onAppear {
                reloadSavedProgramDefinitions()
                if let selectedDefinition = selectedProgramDefinitionRecord {
                    applySavedProgramDefinition(selectedDefinition, isDirty: false)
                }
                refreshCameras()
                refreshSaveProgramDefinitionCommand()
                programDefinitionDirtyChanged(isProgramDefinitionDirty)
            }
            .onChange(of: composite) { _, _ in
                markProgramDefinitionDirty()
            }
            .onChange(of: outputCanvas.state) { _, _ in
                markProgramDefinitionDirty()
            }
            .onChange(of: selectedProgramDefinitionName) { _, _ in
                refreshSaveProgramDefinitionCommand()
            }
            .onChange(of: selectedProgramDefinitionRecord) { _, record in
                if let record {
                    applySavedProgramDefinition(record, isDirty: false)
                }
                refreshSaveProgramDefinitionCommand()
            }
            .onChange(of: isProgramDefinitionDirty) { _, _ in
                programDefinitionDirtyChanged(isProgramDefinitionDirty)
                refreshSaveProgramDefinitionCommand()
            }
            .onDisappear {
                programDefinitionDirtyChanged(false)
                saveProgramDefinitionCommand = nil
            }
            .sheet(isPresented: $isShowingProgramDefinitionJSON) {
                ProgramDefinitionJSONView(jsonText: programDefinitionJSONText)
            }
    }

    private var editorForm: some View {
        Group {
            Section("Video Components") {
                compositeControls
            }

            Section("Audio Channels") {
                audioChannelControls
            }

            Section {
                HStack {
                    Spacer()

                    Button {
                        isShowingProgramDefinitionJSON = true
                    } label: {
                        Label("JSON", systemImage: "curlybraces")
                    }
                    .accessibilityIdentifier("showProgramDefinitionJSONButton")
                }
            }
        }
    }

    private func saveProgramDefinition() {
        let record = currentProgramDefinitionRecord

        if saveProgramDefinitionRecord(record) {
            selectedProgramDefinitionName = record.name
            isProgramDefinitionDirty = false
            programDefinitionDirtyChanged(false)
            refreshSaveProgramDefinitionCommand()
        }
    }

    private func markProgramDefinitionDirty() {
        if !isApplyingSavedProgramDefinition {
            isProgramDefinitionDirty = true
        }
    }

    private var canSaveProgramDefinition: Bool {
        isProgramDefinitionDirty && selectedProgramDefinitionName != nil
    }

    private func refreshSaveProgramDefinitionCommand() {
        saveProgramDefinitionCommand = ProgramDefinitionSaveCommand(
            isEnabled: canSaveProgramDefinition,
            perform: {
                saveProgramDefinition()
            }
        )
    }

    private var currentProgramDefinitionRecord: SavedProgramDefinitionRecord {
        SavedProgramDefinitionRecord(
            name: currentProgramDefinitionName,
            canvasWidth: programWorldCanvasSize.width,
            canvasHeight: programWorldCanvasSize.height,
            frameRateNumerator: max(outputCanvas.programDefinitionFrameRate, 1),
            frameRateDenominator: 1,
            composite: outputCanvas.applying(to: composite)
        )
    }

    private var currentProgramDefinitionName: String {
        selectedProgramDefinitionRecord?.name
            ?? selectedProgramDefinitionName
            ?? "New Program"
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

    private func applySavedProgramDefinition(
        _ record: SavedProgramDefinitionRecord,
        isDirty: Bool
    ) {
        isApplyingSavedProgramDefinition = true
        composite = record.composite
        outputCanvas.sync(from: record)
        isProgramDefinitionDirty = isDirty
        programDefinitionDirtyChanged(isDirty)
        DispatchQueue.main.async {
            isApplyingSavedProgramDefinition = false
            isProgramDefinitionDirty = isDirty
            programDefinitionDirtyChanged(isDirty)
        }
    }

    private func diagnosticDescription(_ error: Error) -> String {
        let nsError = error as NSError
        var parts = [
            "\(type(of: error))",
            "localized=\"\(error.localizedDescription)\"",
            "domain=\(nsError.domain)",
            "code=\(nsError.code)"
        ]
        if let failureReason = nsError.localizedFailureReason {
            parts.append("failureReason=\"\(failureReason)\"")
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=\(underlying.domain)(\(underlying.code)): \(underlying.localizedDescription)")
        }
        return parts.joined(separator: ", ")
    }
}

#if DEBUG
#Preview("Program Definition Editor") {
    ProgramDefinitionDevelopmentViewPreviewHost()
        .frame(width: 560, height: 820)
}

private struct ProgramDefinitionDevelopmentViewPreviewHost: View {
    @State private var selectedProgramDefinitionName =
        LDTXAppUIPreviewFixtures.selectedProgramDefinitionName
    @State private var compositeProgramDefinition = LDTXAppUIPreviewFixtures.compositeProgramDefinition
    @State private var outputCanvas = LDTXAppUIPreviewFixtures.makeOutputCanvasModel()
    @State private var workspaceInputDevices = LDTXAppUIPreviewFixtures.workspaceInputDevices
    @State private var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?

    var body: some View {
        Form {
            ProgramDefinitionDevelopmentView(
                selectedProgramDefinitionName: $selectedProgramDefinitionName,
                compositeProgramDefinition: $compositeProgramDefinition,
                outputCanvas: outputCanvas,
                workspaceInputDevices: $workspaceInputDevices,
                selectedProgramDefinitionRecord: LDTXAppUIPreviewFixtures.selectedProgramDefinitionRecord,
                reloadSavedProgramDefinitions: {},
                refreshCameras: {},
                saveProgramDefinitionRecord: { _ in true },
                programDefinitionDirtyChanged: { _ in },
                saveProgramDefinitionCommand: $saveProgramDefinitionCommand
            )
        }
        .formStyle(.grouped)
    }
}
#endif
