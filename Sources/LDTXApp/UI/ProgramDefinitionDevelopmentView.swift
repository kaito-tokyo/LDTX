// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreMedia
import CoreVideo
import LDTXCapture
import LDTXDash
import LDTXMedia
import LDTXProgram
import LDTXSupport
import LDTXYouTube
import MetalKit
import OSLog
import SwiftUI

struct ProgramDefinitionDevelopmentView: View {
    @Binding var mainWindowState: MainWindowState
    @Binding var compositeProgramDefinition: CompositeProgramDefinition
    @Binding var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?
    @Binding var inputCameraDeviceMappings: [String: String]
    @Binding var inputAudioDeviceMappings: [String: String]
    var cameras: [CameraCaptureSource]
    var audioDevices: [AudioCaptureSource]
    var programCameraInputSource: ProgramCameraInputSource
    var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
    var savedProgramDefinitions: [SavedProgramDefinitionRecord]
    var reloadSavedProgramDefinitions: () -> Void
    var refreshCameras: () -> Void
    var saveProgramDefinitionRecord: (SavedProgramDefinitionRecord) -> Bool
    var programDefinitionDirtyChanged: (Bool) -> Void
    @State private var composite: CompositeProgramDefinition
    @State private var canvasFrameRate = 60
    @State private var programDefinitionName = ""
    @State private var isProgramDefinitionDirty = false
    @State private var isApplyingSavedProgramDefinition = false
    @State private var isShowingProgramDefinitionJSON = false

    init(
        mainWindowState: Binding<MainWindowState>,
        compositeProgramDefinition: Binding<CompositeProgramDefinition>,
        inputCameraDeviceMappings: Binding<[String: String]>,
        inputAudioDeviceMappings: Binding<[String: String]>,
        cameras: [CameraCaptureSource],
        audioDevices: [AudioCaptureSource],
        programCameraInputSource: ProgramCameraInputSource,
        selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?,
        savedProgramDefinitions: [SavedProgramDefinitionRecord],
        reloadSavedProgramDefinitions: @escaping () -> Void,
        refreshCameras: @escaping () -> Void,
        saveProgramDefinitionRecord: @escaping (SavedProgramDefinitionRecord) -> Bool,
        programDefinitionDirtyChanged: @escaping (Bool) -> Void,
        saveProgramDefinitionCommand: Binding<ProgramDefinitionSaveCommand?>
    ) {
        _mainWindowState = mainWindowState
        _compositeProgramDefinition = compositeProgramDefinition
        _saveProgramDefinitionCommand = saveProgramDefinitionCommand
        _inputCameraDeviceMappings = inputCameraDeviceMappings
        _inputAudioDeviceMappings = inputAudioDeviceMappings
        self.cameras = cameras
        self.audioDevices = audioDevices
        self.programCameraInputSource = programCameraInputSource
        self.selectedProgramDefinitionRecord = selectedProgramDefinitionRecord
        self.savedProgramDefinitions = savedProgramDefinitions
        self.reloadSavedProgramDefinitions = reloadSavedProgramDefinitions
        self.refreshCameras = refreshCameras
        self.saveProgramDefinitionRecord = saveProgramDefinitionRecord
        self.programDefinitionDirtyChanged = programDefinitionDirtyChanged
        let selectedDefinition = selectedProgramDefinitionRecord
        _composite = State(initialValue: selectedDefinition?.composite ?? compositeProgramDefinition.wrappedValue)
        _programDefinitionName = State(initialValue: selectedDefinition?.name ?? "")
        if let selectedDefinition {
            _canvasFrameRate = State(
                initialValue: max(
                    selectedDefinition.frameRateNumerator / max(selectedDefinition.frameRateDenominator, 1),
                    1
                )
            )
        }
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
            compositeProgramDefinition = composite
        }
        .onChange(of: canvasFrameRate) { _, _ in
            markProgramDefinitionDirty()
        }
        .onChange(of: programDefinitionName) { _, _ in
            markProgramDefinitionDirty()
        }
        .onChange(of: mainWindowState.selectedSavedProgramDefinitionName) { _, _ in
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
            Section {
                LabeledContent("Canvas Size") {
                    Text(
                        verbatim: canvasSizeLabel(
                            width: programWorldCanvasSize.width,
                            height: programWorldCanvasSize.height
                        )
                    )
                        .foregroundStyle(.secondary)
                }

                Picker("FPS", selection: $canvasFrameRate) {
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

                Picker("Audio Driver", selection: programAudioDriverBinding) {
                    Text("First Received Channel").tag(Optional<String>.none)
                    ForEach(programAudioDriverRows, id: \.key) { row in
                        Text(row.label).tag(Optional(row.key))
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Canvas Settings")
            }

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

    @ViewBuilder
    private func componentParameterControls(
        for step: Binding<CompositeProgramStep>
    ) -> some View {
        let component = step.component
        switch component.wrappedValue {
        case .fillSolidColor:
            solidColorControls(payload: solidColorBinding(for: component))
        case .fillLinearGradient:
            linearGradientControls(payload: linearGradientBinding(for: component))
        case .fillRadialGradient:
            radialGradientControls(payload: radialGradientBinding(for: component))
        case .fillConicGradient:
            conicGradientControls(payload: conicGradientBinding(for: component))
        case .inputCameraDevice:
            inputCameraDeviceControls(
                payload: inputCameraDeviceBinding(for: component),
                mappingKey: composite.inputCameraDeviceMappingKey(for: step.wrappedValue)
            )
        case .testPattern:
            noParameterControls
        }
    }

    private func solidColorControls(payload: Binding<FillSolidColorComponent>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgramColorPicker(
                "colorPicker",
                red: payload.red,
                green: payload.green,
                blue: payload.blue,
                alpha: payload.alpha
            )
            .labelsHidden()
            .accessibilityLabel("colorPicker")
            .accessibilityIdentifier("colorPicker")
            .help("colorPicker")

            solidColorClipControls(payload.clip)
        }
    }

    private func linearGradientControls(payload: Binding<FillLinearGradientComponent>) -> some View {
        Group {
            ProgramParameterSlider("Start X", value: payload.startX, range: 0...1)
            ProgramParameterSlider("Start Y", value: payload.startY, range: 0...1)
            ProgramParameterSlider("End X", value: payload.endX, range: 0...1)
            ProgramParameterSlider("End Y", value: payload.endY, range: 0...1)
            ProgramColorPicker(
                "Start Color",
                red: payload.startRed,
                green: payload.startGreen,
                blue: payload.startBlue,
                alpha: payload.startAlpha
            )
            ProgramColorPicker(
                "End Color",
                red: payload.endRed,
                green: payload.endGreen,
                blue: payload.endBlue,
                alpha: payload.endAlpha
            )
            fillClipControls(payload.clip)
        }
    }

    private func radialGradientControls(payload: Binding<FillRadialGradientComponent>) -> some View {
        Group {
            ProgramParameterSlider("Center X", value: payload.centerX, range: 0...1)
            ProgramParameterSlider("Center Y", value: payload.centerY, range: 0...1)
            ProgramParameterSlider("Inner Radius", value: payload.innerRadius, range: 0...1)
            ProgramParameterSlider("Outer Radius", value: payload.outerRadius, range: 0.01...1.5)
            ProgramColorPicker(
                "Inner Color",
                red: payload.innerRed,
                green: payload.innerGreen,
                blue: payload.innerBlue,
                alpha: payload.innerAlpha
            )
            ProgramColorPicker(
                "Outer Color",
                red: payload.outerRed,
                green: payload.outerGreen,
                blue: payload.outerBlue,
                alpha: payload.outerAlpha
            )
            fillClipControls(payload.clip)
        }
    }

    private func conicGradientControls(payload: Binding<FillConicGradientComponent>) -> some View {
        Group {
            ProgramParameterSlider("Center X", value: payload.centerX, range: 0...1)
            ProgramParameterSlider("Center Y", value: payload.centerY, range: 0...1)
            ProgramParameterSlider("Start Angle", value: payload.startAngleRadians, range: 0...(Float.pi * 2))
            ProgramColorPicker(
                "Start Color",
                red: payload.startRed,
                green: payload.startGreen,
                blue: payload.startBlue,
                alpha: payload.startAlpha
            )
            ProgramColorPicker(
                "End Color",
                red: payload.endRed,
                green: payload.endGreen,
                blue: payload.endBlue,
                alpha: payload.endAlpha
            )
            fillClipControls(payload.clip)
        }
    }

    private func fillClipControls(_ clip: Binding<FillClip>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Clip")
                .font(.headline)

            HStack(spacing: 8) {
                ProgramTableFloatField(value: clip.top, unit: "px", fractionDigits: 0)
                ProgramTableFloatField(value: clip.right, unit: "px", fractionDigits: 0)
                ProgramTableFloatField(value: clip.bottom, unit: "px", fractionDigits: 0)
                ProgramTableFloatField(value: clip.left, unit: "px", fractionDigits: 0)
            }
        }
    }

    private func solidColorClipControls(_ clip: Binding<FillClip>) -> some View {
        HStack(spacing: 8) {
            solidColorClipField(value: clip.top, accessibilityName: "clipTop")
            solidColorClipField(value: clip.right, accessibilityName: "clipRight")
            solidColorClipField(value: clip.bottom, accessibilityName: "clipBottom")
            solidColorClipField(value: clip.left, accessibilityName: "clipLeft")
        }
    }

    private func solidColorClipField(
        value: Binding<Float>,
        accessibilityName: String
    ) -> some View {
        ProgramTableFloatField(value: value, unit: "px", fractionDigits: 0)
            .accessibilityLabel(accessibilityName)
            .accessibilityIdentifier(accessibilityName)
            .help(accessibilityName)
    }

    private func inputCameraDeviceControls(
        payload: Binding<InputDeviceComponent>,
        mappingKey: String
    ) -> some View {
        Group {
            cameraMappingControl(mappingKey: mappingKey)

            Toggle("Remove Background", isOn: payload.removesBackground)

            VStack(alignment: .leading, spacing: 8) {
                Text("Source Crop")
                    .font(.headline)

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("Top")
                            .foregroundStyle(.secondary)
                        ProgramTableFloatField(value: payload.sourceCropTop, unit: "%", fractionDigits: 0)
                        Text("Right")
                            .foregroundStyle(.secondary)
                        ProgramTableFloatField(value: payload.sourceCropRight, unit: "%", fractionDigits: 0)
                    }
                    GridRow {
                        Text("Bottom")
                            .foregroundStyle(.secondary)
                        ProgramTableFloatField(value: payload.sourceCropBottom, unit: "%", fractionDigits: 0)
                        Text("Left")
                            .foregroundStyle(.secondary)
                        ProgramTableFloatField(value: payload.sourceCropLeft, unit: "%", fractionDigits: 0)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Destination")
                    .font(.headline)

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("X")
                            .foregroundStyle(.secondary)
                        ProgramTableFloatField(value: payload.destinationX, unit: "px", fractionDigits: 0)
                        Text("Y")
                            .foregroundStyle(.secondary)
                        ProgramTableFloatField(value: payload.destinationY, unit: "px", fractionDigits: 0)
                    }
                    GridRow {
                        Text("Scale")
                            .foregroundStyle(.secondary)
                        ProgramTableFloatField(value: payload.destinationScale, unit: "x", fractionDigits: 2)
                    }
                }
            }
        }
    }

    private func cameraMappingControl(mappingKey: String) -> some View {
        LabeledContent {
            HStack {
                Spacer(minLength: 12)

                Picker(selection: cameraMappingBinding(mappingKey: mappingKey)) {
                    Text("No camera").tag(Optional<String>.none)
                    ForEach(cameras) { camera in
                        Text(inputCameraDeviceLabel(camera)).tag(Optional(camera.id))
                    }
                } label: {
                    Text(mappingKey)
                }
                .labelsHidden()
                .frame(maxWidth: 300, alignment: .trailing)
                .accessibilityIdentifier("inputCameraDeviceMappingPicker.\(mappingKey)")
            }
        } label: {
            Text("Camera")
                .lineLimit(1)
        }
        .onAppear {
            restoreStoredCameraID(mappingKey: mappingKey)
        }
    }

    private func audioMappingControl(mappingKey: String) -> some View {
        LabeledContent {
            HStack {
                Spacer(minLength: 12)

                Picker(selection: audioMappingBinding(mappingKey: mappingKey)) {
                    Text("No audio").tag(Optional<String>.none)
                    ForEach(audioDevices) { device in
                        Text(inputAudioDeviceLabel(device)).tag(Optional(device.id))
                    }
                } label: {
                    Text(mappingKey)
                }
                .labelsHidden()
                .frame(maxWidth: 300, alignment: .trailing)
                .accessibilityIdentifier("inputAudioDeviceMappingPicker.\(mappingKey)")
            }
        } label: {
            Text("Audio Device")
                .lineLimit(1)
        }
        .onAppear {
            restoreStoredAudioDeviceID(mappingKey: mappingKey)
        }
    }

    private func cameraMappingBinding(mappingKey: String) -> Binding<String?> {
        Binding(
            get: { inputCameraDeviceMappings[mappingKey] },
            set: { newValue in
                if let newValue {
                    inputCameraDeviceMappings[mappingKey] = newValue
                    UserDefaults.standard.set(newValue, forKey: cameraMappingStorageKey(mappingKey))
                } else {
                    inputCameraDeviceMappings.removeValue(forKey: mappingKey)
                    UserDefaults.standard.set("", forKey: cameraMappingStorageKey(mappingKey))
                }
            }
        )
    }

    private func audioMappingBinding(mappingKey: String) -> Binding<String?> {
        Binding(
            get: { inputAudioDeviceMappings[mappingKey] },
            set: { newValue in
                if let newValue {
                    inputAudioDeviceMappings[mappingKey] = newValue
                    UserDefaults.standard.set(newValue, forKey: audioMappingStorageKey(mappingKey))
                } else {
                    inputAudioDeviceMappings.removeValue(forKey: mappingKey)
                    UserDefaults.standard.set("", forKey: audioMappingStorageKey(mappingKey))
                }
            }
        )
    }

    private func restoreStoredCameraID(mappingKey: String) {
        let storedCameraID = UserDefaults.standard.string(forKey: cameraMappingStorageKey(mappingKey)) ?? ""
        if storedCameraID.isEmpty {
            inputCameraDeviceMappings.removeValue(forKey: mappingKey)
        } else {
            inputCameraDeviceMappings[mappingKey] = storedCameraID
        }
    }

    private func restoreStoredAudioDeviceID(mappingKey: String) {
        let storedAudioDeviceID = UserDefaults.standard.string(forKey: audioMappingStorageKey(mappingKey)) ?? ""
        if storedAudioDeviceID.isEmpty {
            inputAudioDeviceMappings.removeValue(forKey: mappingKey)
        } else {
            inputAudioDeviceMappings[mappingKey] = storedAudioDeviceID
        }
    }

    private func cameraMappingStorageKey(_ mappingKey: String) -> String {
        "tokyo.kaito.ldtx.LDTX.InputMappings.camera.\(mappingKey)"
    }

    private func audioMappingStorageKey(_ mappingKey: String) -> String {
        "tokyo.kaito.ldtx.LDTX.InputMappings.audio.\(mappingKey)"
    }

    private func inputCameraDeviceLabel(_ camera: CameraCaptureSource) -> String {
        let source = camera.isExternal ? "USB" : "Camera"
        return "\(source): \(camera.name)"
    }

    private func inputAudioDeviceLabel(_ device: AudioCaptureSource) -> String {
        let source = device.isExternal ? "USB" : "Audio"
        return "\(source): \(device.name)"
    }

    private var noParameterControls: some View {
        Text("No parameters")
            .foregroundStyle(.secondary)
    }

    private func saveProgramDefinition() {
        let record = currentProgramDefinitionRecord

        if isEditingScratchPad {
            if saveProgramDefinitionRecord(record) {
                mainWindowState.selectedSavedProgramDefinitionName = record.name
                programDefinitionName = record.name
                compositeProgramDefinition = record.composite
                isProgramDefinitionDirty = false
                programDefinitionDirtyChanged(false)
                refreshSaveProgramDefinitionCommand()
            }
            return
        }

        programDefinitionName = record.name
        if saveProgramDefinitionRecord(record) {
            mainWindowState.selectedSavedProgramDefinitionName = record.name
            compositeProgramDefinition = record.composite
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
        if isEditingScratchPad {
            return true
        }
        return isProgramDefinitionDirty || mainWindowState.selectedSavedProgramDefinitionName == nil
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
            frameRateNumerator: max(canvasFrameRate, 1),
            frameRateDenominator: 1,
            composite: composite
        )
    }

    private var currentProgramDefinitionName: String {
        isEditingScratchPad ? defaultProgramDefinitionName() : normalizedProgramDefinitionName(programDefinitionName)
    }

    private var isEditingScratchPad: Bool {
        mainWindowState.selectedSavedProgramDefinitionName == nil
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
        programDefinitionName = record.name
        canvasFrameRate = max(record.frameRateNumerator / max(record.frameRateDenominator, 1), 1)
        composite = record.composite
        compositeProgramDefinition = record.composite
        isProgramDefinitionDirty = isDirty
        programDefinitionDirtyChanged(isDirty)
        DispatchQueue.main.async {
            isApplyingSavedProgramDefinition = false
            isProgramDefinitionDirty = isDirty
            programDefinitionDirtyChanged(isDirty)
        }
    }

    private func normalizedProgramDefinitionName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return defaultProgramDefinitionName()
        }
        return trimmed
    }

    private func defaultProgramDefinitionName() -> String {
        let existingNames = Set(savedProgramDefinitions.map(\.name))
        var index = savedProgramDefinitions.count + 1
        var candidate = "New Program \(index)"
        while existingNames.contains(candidate) {
            index += 1
            candidate = "New Program \(index)"
        }
        return candidate
    }

    private var compositeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(composite.steps.indices, id: \.self) { index in
                if let step = compositeStepBinding(index: index) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Picker("Component", selection: compositeStepDefinitionBinding(for: step)) {
                                ForEach(BuiltInProgramDefinition.allCases) { definition in
                                    switch definition {
                                    case .inputCameraDevice:
                                        Text("Input Camera Device").tag(definition)
                                    case .fillSolidColor:
                                        Text("Fill Solid Color").tag(definition)
                                    case .fillLinearGradient:
                                        Text("Fill Linear Gradient").tag(definition)
                                    case .fillRadialGradient:
                                        Text("Fill Radial Gradient").tag(definition)
                                    case .fillConicGradient:
                                        Text("Fill Conic Gradient").tag(definition)
                                    case .testPattern:
                                        Text("Test Pattern").tag(definition)
                                    }
                                }
                            }
                            .labelsHidden()
                            .accessibilityLabel("Component")
                            .accessibilityIdentifier("programComponentPicker")

                            Spacer()

                            Button {
                                moveCompositeStep(index: index, offset: -1)
                            } label: {
                                Image(systemName: "arrow.up")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .disabled(!canMoveCompositeStep(index: index, offset: -1))
                            .help("Move up")

                            Button {
                                moveCompositeStep(index: index, offset: 1)
                            } label: {
                                Image(systemName: "arrow.down")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .disabled(!canMoveCompositeStep(index: index, offset: 1))
                            .help("Move down")

                            Button {
                                deleteCompositeStep(index: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }

                        HStack(spacing: 8) {
                            Text("Name")
                                .foregroundStyle(.secondary)

                            TextField(
                                "Name",
                                text: compositeStepNameBinding(for: step),
                                prompt: Text(compositeStepNamePlaceholder(for: step.wrappedValue, index: index))
                            )
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                        }

                        componentParameterControls(for: step)
                    }
                    .padding(.vertical, 6)
                }
            }

            HStack(spacing: 0) {
                Button {
                    addCompositeStep()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 30, height: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add Component")
                .accessibilityIdentifier("addProgramComponentButton")
            }
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var programVideoPTSInputRows: [(key: String, label: String)] {
        inputCameraDeviceMappingKeys(for: .composite, composite: composite)
            .map { key in (key: key, label: key) }
    }

    private var programVideoPTSInputBinding: Binding<String?> {
        Binding(
            get: {
                if let key = composite.programVideoPTSInputKey,
                   programVideoPTSInputRows.contains(where: { $0.key == key }) {
                    return key
                }
                return programVideoPTSInputRows.first?.key
            },
            set: { key in
                composite.programVideoPTSInputKey = key ?? programVideoPTSInputRows.first?.key
            }
        )
    }

    private var programAudioDriverRows: [(key: String, label: String)] {
        audioChannelKeys(for: .composite, composite: composite)
            .map { key in (key: key, label: key) }
    }

    private var programAudioDriverBinding: Binding<String?> {
        Binding(
            get: {
                if let key = composite.programAudioPTSInputKey,
                   programAudioDriverRows.contains(where: { $0.key == key }) {
                    return key
                }
                return nil
            },
            set: { key in
                composite.programAudioPTSInputKey = key
            }
        )
    }

    private var audioChannelControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(composite.audioChannels.indices, id: \.self) { index in
                if let channel = audioChannelBinding(index: index) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Picker("Component", selection: audioChannelDefinitionBinding(for: channel)) {
                                ForEach(ProgramAudioChannelDefinition.allCases) { definition in
                                    switch definition {
                                    case .inputAudioDevice:
                                        Text("Input Audio Device").tag(definition)
                                    case .silentAudio:
                                        Text("Silent Audio").tag(definition)
                                    case .testPatternAudio:
                                        Text("Test Pattern Audio").tag(definition)
                                    }
                                }
                            }
                            .labelsHidden()
                            .accessibilityLabel("Audio Component")
                            .accessibilityIdentifier("programAudioChannelPicker")

                            Spacer()

                            Button {
                                moveAudioChannel(index: index, offset: -1)
                            } label: {
                                Image(systemName: "arrow.up")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .disabled(!canMoveAudioChannel(index: index, offset: -1))
                            .help("Move up")

                            Button {
                                moveAudioChannel(index: index, offset: 1)
                            } label: {
                                Image(systemName: "arrow.down")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .disabled(!canMoveAudioChannel(index: index, offset: 1))
                            .help("Move down")

                            Button {
                                deleteAudioChannel(index: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }

                        HStack(spacing: 8) {
                            Text("Name")
                                .foregroundStyle(.secondary)

                            TextField(
                                "Name",
                                text: audioChannelNameBinding(for: channel),
                                prompt: Text(audioChannelNamePlaceholder(for: channel.wrappedValue, index: index))
                            )
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                        }

                        audioChannelParameterControls(for: channel)
                    }
                    .padding(.vertical, 6)
                }
            }

            HStack(spacing: 0) {
                Button {
                    addAudioChannel()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 30, height: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add Audio Channel")
                .accessibilityIdentifier("addProgramAudioChannelButton")
            }
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func addCompositeStep() {
        let component = ProgramComponent.inputCameraDevice(InputDeviceComponent())
        let name = nextCompositeStepName(for: component.definition)
        composite.steps.append(CompositeProgramStep(name: name, component: component))
    }

    private func addAudioChannel() {
        let component = ProgramAudioChannelComponent.inputAudioDevice(InputAudioDeviceComponent())
        let name = nextAudioChannelName(for: component.definition)
        composite.audioChannels.append(ProgramAudioChannel(name: name, component: component))
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

    private func deleteCompositeStep(index: Int) {
        guard composite.steps.indices.contains(index) else { return }
        composite.steps.remove(at: index)
    }

    private func deleteAudioChannel(index: Int) {
        guard composite.audioChannels.indices.contains(index) else { return }
        composite.audioChannels.remove(at: index)
    }

    private func canMoveCompositeStep(index: Int, offset: Int) -> Bool {
        guard composite.steps.indices.contains(index) else { return false }
        return composite.steps.indices.contains(index + offset)
    }

    private func moveCompositeStep(index: Int, offset: Int) {
        guard composite.steps.indices.contains(index) else { return }
        let destination = index + offset
        guard composite.steps.indices.contains(destination) else {
            return
        }
        composite.steps.swapAt(index, destination)
    }

    private func canMoveAudioChannel(index: Int, offset: Int) -> Bool {
        guard composite.audioChannels.indices.contains(index) else { return false }
        return composite.audioChannels.indices.contains(index + offset)
    }

    private func moveAudioChannel(index: Int, offset: Int) {
        guard composite.audioChannels.indices.contains(index) else { return }
        let destination = index + offset
        guard composite.audioChannels.indices.contains(destination) else {
            return
        }
        composite.audioChannels.swapAt(index, destination)
    }

    private func compositeStepBinding(index: Int) -> Binding<CompositeProgramStep>? {
        guard composite.steps.indices.contains(index) else {
            return nil
        }
        return Binding(
            get: { composite.steps[index] },
            set: { composite.steps[index] = $0 }
        )
    }

    private func audioChannelBinding(index: Int) -> Binding<ProgramAudioChannel>? {
        guard composite.audioChannels.indices.contains(index) else {
            return nil
        }
        return Binding(
            get: { composite.audioChannels[index] },
            set: { composite.audioChannels[index] = $0 }
        )
    }

    private func compositeStepDefinitionBinding(
        for step: Binding<CompositeProgramStep>
    ) -> Binding<BuiltInProgramDefinition> {
        Binding(
            get: { step.wrappedValue.component.definition },
            set: { newValue in
                step.wrappedValue.component = .defaultComponent(for: newValue)
            }
        )
    }

    private func compositeStepNameBinding(
        for step: Binding<CompositeProgramStep>
    ) -> Binding<String> {
        Binding(
            get: { step.wrappedValue.name ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                step.wrappedValue.name = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    private func compositeStepNamePlaceholder(for step: CompositeProgramStep, index: Int) -> String {
        return "\(step.component.definition.rawValue) \(index + 1)"
    }

    private func audioChannelDefinitionBinding(
        for channel: Binding<ProgramAudioChannel>
    ) -> Binding<ProgramAudioChannelDefinition> {
        Binding(
            get: { channel.wrappedValue.component.definition },
            set: { newValue in
                channel.wrappedValue.component = .defaultComponent(for: newValue)
            }
        )
    }

    private func audioChannelNameBinding(
        for channel: Binding<ProgramAudioChannel>
    ) -> Binding<String> {
        Binding(
            get: { channel.wrappedValue.name ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                channel.wrappedValue.name = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    private func audioChannelNamePlaceholder(for channel: ProgramAudioChannel, index: Int) -> String {
        return "\(channel.component.definition.rawValue) \(index + 1)"
    }

    private func nextCompositeStepName(for definition: BuiltInProgramDefinition) -> String {
        nextProgramElementName(prefix: definition.rawValue, existingNames: composite.steps.compactMap(\.name))
    }

    private func nextAudioChannelName(for definition: ProgramAudioChannelDefinition) -> String {
        nextProgramElementName(prefix: definition.rawValue, existingNames: composite.audioChannels.compactMap(\.name))
    }

    private func nextProgramElementName(prefix: String, existingNames: [String]) -> String {
        let normalizedExistingNames = Set(
            existingNames
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        var index = 1
        while normalizedExistingNames.contains("\(prefix) \(index)") {
            index += 1
        }
        return "\(prefix) \(index)"
    }

    @ViewBuilder
    private func audioChannelParameterControls(
        for channel: Binding<ProgramAudioChannel>
    ) -> some View {
        let component = channel.component
        switch component.wrappedValue {
        case .inputAudioDevice:
            audioMappingControl(mappingKey: composite.inputAudioDeviceMappingKey(for: channel.wrappedValue))
        case .silentAudio, .testPatternAudio:
            noParameterControls
        }
    }

    private func solidColorBinding(for component: Binding<ProgramComponent>) -> Binding<FillSolidColorComponent> {
        Binding(
            get: {
                if case let .fillSolidColor(payload) = component.wrappedValue {
                    return payload
                }
                return FillSolidColorComponent()
            },
            set: { component.wrappedValue = .fillSolidColor($0) }
        )
    }

    private func linearGradientBinding(for component: Binding<ProgramComponent>) -> Binding<FillLinearGradientComponent> {
        Binding(
            get: {
                if case let .fillLinearGradient(payload) = component.wrappedValue {
                    return payload
                }
                return FillLinearGradientComponent()
            },
            set: { component.wrappedValue = .fillLinearGradient($0) }
        )
    }

    private func radialGradientBinding(for component: Binding<ProgramComponent>) -> Binding<FillRadialGradientComponent> {
        Binding(
            get: {
                if case let .fillRadialGradient(payload) = component.wrappedValue {
                    return payload
                }
                return FillRadialGradientComponent()
            },
            set: { component.wrappedValue = .fillRadialGradient($0) }
        )
    }

    private func conicGradientBinding(for component: Binding<ProgramComponent>) -> Binding<FillConicGradientComponent> {
        Binding(
            get: {
                if case let .fillConicGradient(payload) = component.wrappedValue {
                    return payload
                }
                return FillConicGradientComponent()
            },
            set: { component.wrappedValue = .fillConicGradient($0) }
        )
    }

    private func inputCameraDeviceBinding(for component: Binding<ProgramComponent>) -> Binding<InputDeviceComponent> {
        Binding(
            get: {
                if case let .inputCameraDevice(payload) = component.wrappedValue {
                    return payload
                }
                return InputDeviceComponent()
            },
            set: { component.wrappedValue = .inputCameraDevice($0) }
        )
    }

}

private struct ProgramDefinitionJSONView: View {
    @Environment(\.dismiss) private var dismiss
    var jsonText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Program Definition JSON")
                    .font(.headline)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                Text(jsonText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 520)
    }
}

struct ProgramPreviewPane: View {
    @Binding var mainWindowState: MainWindowState
    var programCameraInputSource: ProgramCameraInputSource
    var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
    var compositeProgramDefinition: CompositeProgramDefinition
    var inputCameraDeviceMappings: [String: String]
    var editProgram: (() -> Void)?
    @StateObject private var previewController: ProgramPreviewController

    init(
        mainWindowState: Binding<MainWindowState>,
        programCameraInputSource: ProgramCameraInputSource,
        selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?,
        compositeProgramDefinition: CompositeProgramDefinition,
        inputCameraDeviceMappings: [String: String],
        editProgram: (() -> Void)? = nil
    ) {
        _mainWindowState = mainWindowState
        self.programCameraInputSource = programCameraInputSource
        self.selectedProgramDefinitionRecord = selectedProgramDefinitionRecord
        self.compositeProgramDefinition = compositeProgramDefinition
        self.inputCameraDeviceMappings = inputCameraDeviceMappings
        self.editProgram = editProgram
        _previewController = StateObject(
            wrappedValue: ProgramPreviewController(cameraInputSource: programCameraInputSource)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(selectedProgramDefinitionRecord?.name ?? "Program Video Components")
                    .font(.headline)
                Spacer()
                Text(previewStatus)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let editProgram {
                    Button {
                        editProgram()
                    } label: {
                        Label("Edit Program", systemImage: "pencil")
                    }
                    .disabled(mainWindowState.selectedSavedProgramDefinitionName == nil)
                }
            }

            ZStack {
                Rectangle()
                    .fill(.black)
                ProgramPixelBufferPreview(
                    controller: previewController,
                    frameRate: previewFrameRate,
                    taskPriority: .utility
                )
            }
            .aspectRatio(Double(previewSize.width) / Double(previewSize.height), contentMode: .fit)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            configurePreview()
        }
        .onChange(of: mainWindowState.selectedResolution) { _, _ in configurePreview() }
        .onChange(of: mainWindowState.selectedFrameRate) { _, _ in configurePreview() }
        .onChange(of: selectedProgramDefinitionRecord) { _, _ in configurePreview() }
        .onChange(of: compositeProgramDefinition) { _, _ in configurePreview() }
        .onChange(of: inputCameraDeviceMappings) { _, _ in configurePreview() }
    }

    private var previewSize: (width: Int, height: Int) {
        captureTargetSize(for: mainWindowState.selectedResolution)
    }

    private var previewFrameRate: Int {
        if let selectedDefinition = selectedProgramDefinitionRecord {
            return max(
                selectedDefinition.frameRateNumerator / max(selectedDefinition.frameRateDenominator, 1),
                1
            )
        }
        return mainWindowState.selectedFrameRate == .fps60 ? 60 : 30
    }

    private var previewStatus: String {
        "\(previewSize.width)x\(previewSize.height) @ \(previewFrameRate) fps"
    }

    @MainActor
    private func configurePreview() {
        let snapshot = previewSnapshot()
        previewController.configure(snapshot: snapshot)
    }

    @MainActor
    private func previewSnapshot() -> ProgramPreviewSnapshot {
        let size = previewSize
        let definition = ProgramDefinition.composite
        let composite = compositeProgramDefinition
        return ProgramPreviewSnapshot(
            definition: definition,
            composite: composite,
            canvasWidth: programWorldCanvasSize.width,
            canvasHeight: programWorldCanvasSize.height,
            outputWidth: size.width,
            outputHeight: size.height,
            frameRate: previewFrameRate,
            timeSeconds: Float(ProcessInfo.processInfo.systemUptime),
            programVideoPTSInputKey: programVideoPTSInputKey(
                for: definition,
                composite: composite
            ),
            programAudioDriverKey: programAudioDriverKey(
                for: definition,
                composite: composite
            ),
            cameraIDsByInputKey: mappedInputCameraDeviceIDs(
                for: definition,
                composite: composite,
                inputCameraDeviceMappings: inputCameraDeviceMappings
            ),
            backgroundRemovalInputKeys: backgroundRemovalInputCameraDeviceKeys(
                for: definition,
                composite: composite
            )
        )
    }
}

enum ProgramPreviewError: Error {
    case pixelBufferCreationFailed
}

struct ProgramPreviewSnapshot: Sendable {
    var definition: ProgramDefinition
    var composite: CompositeProgramDefinition
    var canvasWidth: Int
    var canvasHeight: Int
    var outputWidth: Int
    var outputHeight: Int
    var frameRate: Int
    var timeSeconds: Float
    var programVideoPTSInputKey: String?
    var programAudioDriverKey: String?
    var cameraIDsByInputKey: [String: String]
    var backgroundRemovalInputKeys: Set<String>

    var diagnosticDescription: String {
        "definition=\(definition.debugName), canvas=\(canvasWidth)x\(canvasHeight), output=\(outputWidth)x\(outputHeight), fps=\(frameRate), programVideoPTSInputKey=\(programVideoPTSInputKey ?? "nil"), programAudioDriverKey=\(programAudioDriverKey ?? "nil"), cameraIDs=\(cameraIDsByInputKey), backgroundRemovalInputKeys=\(backgroundRemovalInputKeys.sorted()), steps=\(composite.steps.map { $0.component.definition.rawValue }.joined(separator: ","))"
    }
}

private extension ProgramDefinition {
    var debugName: String {
        switch self {
        case .fillSolidColor:
            "fillSolidColor"
        case .fillLinearGradient:
            "fillLinearGradient"
        case .fillRadialGradient:
            "fillRadialGradient"
        case .fillConicGradient:
            "fillConicGradient"
        case .inputCameraDevice:
            "inputCameraDevice"
        case .testPattern:
            "testPattern"
        case .composite:
            "composite"
        }
    }
}

struct ProgramPreviewFrame: @unchecked Sendable {
    var pixelBuffer: CVPixelBuffer
    var presentationTime: CMTime?
    var isPreparingRenderResources: Bool = false
}

private final class ProgramPreviewController: ObservableObject, @unchecked Sendable {
    private let lock = NSLock()
    private let previewRenderer: ProgramPreviewRenderWorker
    private var renderTask: Task<Void, Never>?
    private var snapshot: ProgramPreviewSnapshot?
    private var latestFrame: ProgramPreviewFrame?
    private var sessionID = 0

    init(cameraInputSource: ProgramCameraInputSource) {
        previewRenderer = ProgramPreviewRenderWorker(cameraInputSource: cameraInputSource)
    }

    func configure(snapshot: ProgramPreviewSnapshot) {
        lock.lock()
        let shouldClearFrame = self.snapshot?.outputWidth != snapshot.outputWidth ||
            self.snapshot?.outputHeight != snapshot.outputHeight
        self.snapshot = snapshot
        if shouldClearFrame {
            latestFrame = nil
        }
        lock.unlock()
    }

    func start(priority: TaskPriority = .userInitiated) {
        let currentSessionID: Int
        lock.lock()
        guard renderTask == nil else {
            lock.unlock()
            return
        }
        sessionID += 1
        currentSessionID = sessionID
        lock.unlock()

        renderTask = Task(priority: priority) { [weak self] in
            await self?.runRenderLoop(sessionID: currentSessionID)
        }
    }

    func stop() {
        let currentSessionID: Int
        lock.lock()
        currentSessionID = sessionID
        renderTask?.cancel()
        renderTask = nil
        latestFrame = nil
        lock.unlock()

        let previewRenderer = previewRenderer
        Task {
            await previewRenderer.endSession(currentSessionID)
        }
    }

    func latestPixelBuffer() -> CVPixelBuffer? {
        lock.lock()
        let pixelBuffer = latestFrame?.pixelBuffer
        lock.unlock()
        return pixelBuffer
    }

    func isPreparingRenderResources() -> Bool {
        lock.lock()
        let isPreparing = latestFrame?.isPreparingRenderResources ?? false
        lock.unlock()
        return isPreparing
    }

    private func currentSnapshot() -> ProgramPreviewSnapshot? {
        lock.lock()
        let snapshot = snapshot
        lock.unlock()
        return snapshot
    }

    private func setLatestFrame(_ frame: ProgramPreviewFrame) {
        lock.lock()
        latestFrame = frame
        lock.unlock()
    }

    private func runRenderLoop(sessionID: Int) async {
        await previewRenderer.beginSession(sessionID)

        while !Task.isCancelled {
            guard var snapshot = currentSnapshot() else {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }

            snapshot.timeSeconds = Float(ProcessInfo.processInfo.systemUptime)
            do {
                let frame = try await previewRenderer.render(
                    snapshot: snapshot,
                    sessionID: sessionID
                )
                guard !Task.isCancelled else {
                    return
                }
                setLatestFrame(frame)
            } catch {
                if error is CancellationError {
                    return
                }
                logProgramPreviewRenderFailed(error, snapshot: snapshot)
            }

            let frameRate = max(snapshot.frameRate, 1)
            let interval = 1_000_000_000 / UInt64(frameRate)
            try? await Task.sleep(nanoseconds: interval)
        }
    }
}

actor ProgramPreviewRenderWorker {
    private var activeSessionID: Int?
    private var compositor: VideoCompositor?
    private let cameraInputSource: ProgramCameraInputSource
    private var outputPixelBuffers: [CVPixelBuffer] = []
    private var nextOutputPixelBufferIndex = 0
    private var activeWidth: Int?
    private var activeHeight: Int?
    private var retainedCameraRequests: Set<ProgramCameraInputRequest> = []
    private var latestCameraFrameSerialByInputKey: [String: Int] = [:]

    init(cameraInputSource: ProgramCameraInputSource) {
        self.cameraInputSource = cameraInputSource
    }

    func beginSession(_ sessionID: Int) {
        activeSessionID = sessionID
    }

    func endSession(_ sessionID: Int) async {
        if activeSessionID == sessionID {
            activeSessionID = nil
        }
        await releaseCameraInputIfNeeded()
    }

    func render(
        snapshot: ProgramPreviewSnapshot,
        sessionID: Int
    ) async throws -> ProgramPreviewFrame {
        guard activeSessionID == sessionID else {
            throw CancellationError()
        }

        let outputWidth = max(snapshot.outputWidth, 1)
        let outputHeight = max(snapshot.outputHeight, 1)
        let canvasWidth = max(snapshot.canvasWidth, 1)
        let canvasHeight = max(snapshot.canvasHeight, 1)
        do {
            try await prepareSize(width: outputWidth, height: outputHeight)
            let compositor = try makeCompositor(width: outputWidth, height: outputHeight)
            let (sourcesByInputKey, presentationTime, isPreparingRenderResources) = try await makeSourcesByInputKey(snapshot: snapshot)
            let outputPixelBuffer = try makeOutputPixelBuffer(width: outputWidth, height: outputHeight)
            let components = snapshot.definition.components(
                worldWidth: canvasWidth,
                worldHeight: canvasHeight,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                composite: snapshot.composite,
                sourcesByInputKey: sourcesByInputKey,
                timeSeconds: snapshot.timeSeconds
            )
            try compositor.render(components, into: outputPixelBuffer)
            return ProgramPreviewFrame(
                pixelBuffer: outputPixelBuffer,
                presentationTime: presentationTime,
                isPreparingRenderResources: isPreparingRenderResources
            )
        } catch {
            if !(error is CancellationError) {
                logProgramPreviewWorkerFailed(error, snapshot: snapshot)
            }
            throw error
        }
    }

    private func prepareSize(width: Int, height: Int) async throws {
        if activeWidth == width && activeHeight == height {
            return
        }

        compositor = nil
        outputPixelBuffers = try (0..<3).map { _ in
            try Self.makeNV12PixelBuffer(width: width, height: height)
        }
        nextOutputPixelBufferIndex = 0
        latestCameraFrameSerialByInputKey = [:]
        activeWidth = width
        activeHeight = height
    }

    private func makeCompositor(width: Int, height: Int) throws -> VideoCompositor {
        if let compositor {
            return compositor
        }
        let compositor = try VideoCompositor(configuration: VideoCompositorConfiguration(
            width: width,
            height: height,
            pixelBufferPoolMinimumBufferCount: 3
        ))
        self.compositor = compositor
        return compositor
    }

    private func makeSourcesByInputKey(
        snapshot: ProgramPreviewSnapshot
    ) async throws -> (
        sourcesByInputKey: [String: MetalVideoSource],
        presentationTime: CMTime?,
        isPreparingRenderResources: Bool
    ) {
        var requestsByInputKey: [String: ProgramCameraInputRequest] = [:]
        for (key, cameraID) in snapshot.cameraIDsByInputKey {
            requestsByInputKey[key] = ProgramCameraInputRequest(
                cameraID: cameraID,
                width: snapshot.outputWidth,
                height: snapshot.outputHeight,
                frameRate: snapshot.frameRate
            )
        }
        let requestedRequests = Set(requestsByInputKey.values)

        for request in retainedCameraRequests.subtracting(requestedRequests) {
            await cameraInputSource.release(request: request)
        }
        for request in requestedRequests.subtracting(retainedCameraRequests) {
            try await cameraInputSource.retain(request: request)
        }
        retainedCameraRequests = requestedRequests

        let backgroundRemovalRequests = Set(requestsByInputKey.compactMap { key, request in
            snapshot.backgroundRemovalInputKeys.contains(key) ? request : nil
        })
        for request in backgroundRemovalRequests {
            await cameraInputSource.beginPreparingBackgroundRemoval(for: request)
        }

        var sourcesByInputKey: [String: MetalVideoSource] = [:]
        var presentationTime: CMTime?
        var isPreparingRenderResources = false
        for (key, request) in requestsByInputKey {
            if let frame = await cameraInputSource.latestFrame(
                for: request,
                removesBackground: snapshot.backgroundRemovalInputKeys.contains(key)
            ) {
                latestCameraFrameSerialByInputKey[key] = frame.serial
                sourcesByInputKey[key] = frame.source
                if key == snapshot.programVideoPTSInputKey {
                    presentationTime = frame.sourcePresentationTime
                }
                isPreparingRenderResources = isPreparingRenderResources || frame.isPreparingRenderResources
            }
        }
        return (sourcesByInputKey, presentationTime, isPreparingRenderResources)
    }

    private func releaseCameraInputIfNeeded() async {
        for request in retainedCameraRequests {
            await cameraInputSource.release(request: request)
        }
        retainedCameraRequests = []
        latestCameraFrameSerialByInputKey = [:]
    }

    private func makeOutputPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        guard !outputPixelBuffers.isEmpty else {
            throw ProgramPreviewError.pixelBufferCreationFailed
        }
        let pixelBuffer = outputPixelBuffers[nextOutputPixelBufferIndex]
        nextOutputPixelBufferIndex = (nextOutputPixelBufferIndex + 1) % outputPixelBuffers.count
        return pixelBuffer
    }

    private static func makeNV12PixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            logProgramPreviewPixelBufferCreateFailed(
                status: status,
                width: width,
                height: height,
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            )
            throw ProgramPreviewError.pixelBufferCreationFailed
        }
        return pixelBuffer
    }

}
private struct ProgramFloatField: View {
    var title: String
    @Binding var value: Float
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(_ title: String, value: Binding<Float>) {
        self.title = title
        _value = value
        _text = State(initialValue: Self.format(value.wrappedValue))
    }

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 86)
                .focused($isFocused)
                .onSubmit {
                    commitText()
                }
                .onChange(of: text) { _, _ in
                    commitText()
                }
                .onChange(of: value) { _, newValue in
                    if !isFocused {
                        text = Self.format(newValue)
                    }
                }
        }
        .frame(width: 124)
    }

    private func commitText() {
        guard let parsed = Float(text) else {
            return
        }
        value = parsed
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.3f", value)
    }
}

private struct ProgramIntegerField: View {
    @Binding var value: Int
    var minimum: Int
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(value: Binding<Int>, minimum: Int) {
        _value = value
        self.minimum = minimum
        _text = State(initialValue: String(value.wrappedValue))
    }

    var body: some View {
        TextField("Value", text: $text)
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .focused($isFocused)
            .onSubmit {
                commitText()
            }
            .onChange(of: text) { _, _ in
                commitText()
            }
            .onChange(of: value) { _, newValue in
                if !isFocused {
                    text = String(newValue)
                }
            }
    }

    private func commitText() {
        guard let parsed = Int(text) else {
            return
        }
        value = max(parsed, minimum)
    }
}

private struct ProgramTableFloatField: View {
    @Binding var value: Float
    var unit: String
    var fractionDigits: Int
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(value: Binding<Float>, unit: String, fractionDigits: Int = 3) {
        _value = value
        self.unit = unit
        self.fractionDigits = fractionDigits
        _text = State(initialValue: Self.format(value.wrappedValue, fractionDigits: fractionDigits))
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField("Value", text: $text)
                .textFieldStyle(.plain)
                .labelsHidden()
                .focused($isFocused)
                .onSubmit {
                    commitText()
                }
                .onChange(of: text) { _, _ in
                    commitText()
                }
                .onChange(of: value) { _, newValue in
                    if !isFocused {
                        text = Self.format(newValue, fractionDigits: fractionDigits)
                    }
                }
            Text(unit)
                .foregroundStyle(.secondary)
                .monospaced()
                .frame(minWidth: 24, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commitText() {
        guard let parsed = Float(text) else {
            return
        }
        value = parsed
    }

    private static func format(_ value: Float, fractionDigits: Int) -> String {
        String(format: "%.\(fractionDigits)f", value)
    }
}

private struct ProgramColorPicker: View {
    var title: String
    @Binding var red: Float
    @Binding var green: Float
    @Binding var blue: Float
    @Binding var alpha: Float

    init(
        _ title: String,
        red: Binding<Float>,
        green: Binding<Float>,
        blue: Binding<Float>,
        alpha: Binding<Float>
    ) {
        self.title = title
        _red = red
        _green = green
        _blue = blue
        _alpha = alpha
    }

    var body: some View {
        ColorPicker(title, selection: color, supportsOpacity: true)
    }

    private var color: Binding<Color> {
        Binding(
            get: {
                Color(
                    .sRGB,
                    red: Double(red),
                    green: Double(green),
                    blue: Double(blue),
                    opacity: Double(alpha)
                )
            },
            set: { newValue in
                let color = NSColor(newValue).usingColorSpace(.sRGB) ?? NSColor(newValue)
                red = Float(color.redComponent)
                green = Float(color.greenComponent)
                blue = Float(color.blueComponent)
                alpha = Float(color.alphaComponent)
            }
        )
    }
}

private struct ProgramParameterSlider: View {
    var title: String
    @Binding var value: Float
    var range: ClosedRange<Float>

    init(_ title: String, value: Binding<Float>, range: ClosedRange<Float>) {
        self.title = title
        _value = value
        self.range = range
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: valueAsDouble, in: Double(range.lowerBound)...Double(range.upperBound))
                Text(value.formatted(.number.precision(.fractionLength(2))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    private var valueAsDouble: Binding<Double> {
        Binding(
            get: { Double(value) },
            set: { value = Float($0) }
        )
    }
}

private func logProgramPreviewRenderFailed(_ error: Error, snapshot: ProgramPreviewSnapshot) {
    let nsError = error as NSError
    programPreviewLogger.error(
        "Program preview render failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) canvasWidth=\(snapshot.canvasWidth, privacy: .public) canvasHeight=\(snapshot.canvasHeight, privacy: .public) outputWidth=\(snapshot.outputWidth, privacy: .public) outputHeight=\(snapshot.outputHeight, privacy: .public) frameRate=\(snapshot.frameRate, privacy: .public) timeSeconds=\(snapshot.timeSeconds, privacy: .public) cameraInputCount=\(snapshot.cameraIDsByInputKey.count, privacy: .public) backgroundRemovalInputCount=\(snapshot.backgroundRemovalInputKeys.count, privacy: .public) stepCount=\(snapshot.composite.steps.count, privacy: .public)"
    )
}

private func logProgramPreviewWorkerFailed(_ error: Error, snapshot: ProgramPreviewSnapshot) {
    let nsError = error as NSError
    programPreviewLogger.error(
        "Program preview worker failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) canvasWidth=\(snapshot.canvasWidth, privacy: .public) canvasHeight=\(snapshot.canvasHeight, privacy: .public) outputWidth=\(snapshot.outputWidth, privacy: .public) outputHeight=\(snapshot.outputHeight, privacy: .public) frameRate=\(snapshot.frameRate, privacy: .public) timeSeconds=\(snapshot.timeSeconds, privacy: .public) cameraInputCount=\(snapshot.cameraIDsByInputKey.count, privacy: .public) backgroundRemovalInputCount=\(snapshot.backgroundRemovalInputKeys.count, privacy: .public) stepCount=\(snapshot.composite.steps.count, privacy: .public)"
    )
}

private func logProgramPreviewPixelBufferCreateFailed(
    status: CVReturn,
    width: Int,
    height: Int,
    pixelFormat: OSType
) {
    programPreviewLogger.error(
        "Program preview pixel buffer creation failed status=\(status, privacy: .public) width=\(width, privacy: .public) height=\(height, privacy: .public) pixelFormat=\(pixelFormat, privacy: .public)"
    )
}

private let programPreviewLogger = Logger(
    subsystem: "tokyo.kaito.ldtx",
    category: "ProgramPreview"
)

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

private func fourCC(_ value: OSType) -> String {
    let scalars = [
        UnicodeScalar((value >> 24) & 0xff),
        UnicodeScalar((value >> 16) & 0xff),
        UnicodeScalar((value >> 8) & 0xff),
        UnicodeScalar(value & 0xff)
    ]
    let string = scalars.compactMap { $0 }.map(String.init).joined()
    return string.isEmpty ? "\(value)" : "\(string)(\(value))"
}

private struct ProgramPixelBufferPreview: NSViewRepresentable {
    var controller: ProgramPreviewController
    var frameRate: Int
    var taskPriority: TaskPriority = .userInitiated

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        controller.start(priority: taskPriority)
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = max(frameRate, 1)
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.controller = controller
        nsView.preferredFramesPerSecond = max(frameRate, 1)
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        coordinator.controller.stop()
        nsView.delegate = nil
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let device = MTLCreateSystemDefaultDevice()
        var controller: ProgramPreviewController
        private let commandQueue: MTLCommandQueue?
        private let textureCache: CVMetalTextureCache?
        private let previewPipeline: MTLComputePipelineState?

        init(controller: ProgramPreviewController) {
            self.controller = controller
            commandQueue = device?.makeCommandQueue()
            if let device {
                var cache: CVMetalTextureCache?
                CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
                textureCache = cache
                previewPipeline = try? VideoCompositor.makePreviewNV12ToBGRAPipeline(device: device)
            } else {
                textureCache = nil
                previewPipeline = nil
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let pipeline = previewPipeline,
                  view.drawableSize.width > 0,
                  view.drawableSize.height > 0 else {
                return
            }

            guard let pixelBuffer = controller.latestPixelBuffer() else {
                drawBlack(drawable: drawable, commandBuffer: commandBuffer)
                return
            }
            if controller.isPreparingRenderResources() {
                drawGray(drawable: drawable, commandBuffer: commandBuffer)
                return
            }

            guard let sourceLuma = texture(
                from: pixelBuffer,
                pixelFormat: .r8Unorm,
                planeIndex: 0
            ),
                  let sourceChroma = texture(
                    from: pixelBuffer,
                    pixelFormat: .rg8Unorm,
                    planeIndex: 1
                  ),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                drawBlack(drawable: drawable, commandBuffer: commandBuffer)
                return
            }

            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(sourceLuma, index: 0)
            encoder.setTexture(sourceChroma, index: 1)
            encoder.setTexture(drawable.texture, index: 2)
            dispatch(encoder: encoder, pipeline: pipeline, width: drawable.texture.width, height: drawable.texture.height)
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func texture(
            from pixelBuffer: CVPixelBuffer,
            pixelFormat: MTLPixelFormat,
            planeIndex: Int
        ) -> MTLTexture? {
            guard let textureCache else {
                return nil
            }

            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
            var cvMetalTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                pixelFormat,
                width,
                height,
                planeIndex,
                &cvMetalTexture
            )
            guard status == kCVReturnSuccess,
                  let cvMetalTexture,
                  let texture = CVMetalTextureGetTexture(cvMetalTexture) else {
                return nil
            }
            return texture
        }

        private func dispatch(
            encoder: MTLComputeCommandEncoder,
            pipeline: MTLComputePipelineState,
            width: Int,
            height: Int
        ) {
            let threadgroupWidth = pipeline.threadExecutionWidth
            let threadgroupHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadgroupWidth)
            let threadsPerThreadgroup = MTLSize(width: threadgroupWidth, height: threadgroupHeight, depth: 1)
            let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        }

        private func drawBlack(
            drawable: CAMetalDrawable,
            commandBuffer: MTLCommandBuffer
        ) {
            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = drawable.texture
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                encoder.endEncoding()
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func drawGray(
            drawable: CAMetalDrawable,
            commandBuffer: MTLCommandBuffer
        ) {
            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = drawable.texture
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.28, 0.28, 0.28, 1)
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                encoder.endEncoding()
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
