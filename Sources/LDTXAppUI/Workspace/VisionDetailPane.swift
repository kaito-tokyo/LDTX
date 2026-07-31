// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXInternalProtocols
import LDTXWorkspace
import SwiftUI

struct VisionDetailPane: View {
    @State private var ocrLanguageDrafts: [String: String] = [:]
    @FocusState private var focusedOCRLanguageVisionID: String?
    @Binding var visions: [WorkspaceVisionDefinition]
    var visionID: String
    var inputDevices: [WorkspaceInputDeviceRecord]
    var runtimePresenter: any VisionRuntimePresenting
    var analyze: (WorkspaceVisionDefinition) -> Void
    var delete: (String) -> Void

    var body: some View {
        if let index = visions.firstIndex(where: { $0.id == visionID }) {
            Form {
                Section("Result — Local Mode, No Data Sent to the Internet") {
                    Text(runtimePresenter.result(forVisionID: visionID) ?? "No analysis result")
                        .textSelection(.enabled)
                        .foregroundStyle(runtimePresenter.result(forVisionID: visionID) == nil ? .secondary : .primary)
                }

                Section("Source") {
                    Picker("Source", selection: sourceBinding(index: index)) {
                        Text("Current Program Output").tag("program")
                        ForEach(inputDevices.filter { $0.kind == .video }, id: \.id) { device in
                            Text(device.name).tag("input:\(device.name)")
                        }
                        if case let .inputDevice(name) = visions[index].source,
                           !inputDevices.contains(where: { $0.name == name }) {
                            Text("Missing Input Device (\(name))").tag("input:\(name)")
                        }
                    }
                    cropControls(index: index)
                    Picker("Update", selection: updateIntervalBinding(index: index)) {
                        Text("Manual").tag(0.0)
                        Text("Every 0.5 Seconds").tag(0.5)
                        Text("Every Second").tag(1.0)
                        Text("Every 2 Seconds").tag(2.0)
                        Text("Every 5 Seconds").tag(5.0)
                        Text("Every 10 Seconds").tag(10.0)
                    }
                }

                if case .visionLanguageModel = visions[index].definition {
                Section("System Prompt") {
                    TextEditor(text: $visions[index].systemPrompt)
                        .font(.body.monospaced())
                        .frame(minHeight: 180, maxHeight: 320)
                        .accessibilityLabel("System Prompt")
                }

                Section("User Prompt") {
                    TextEditor(text: $visions[index].userPrompt)
                        .font(.body.monospaced())
                        .frame(minHeight: 80, maxHeight: 180)
                        .accessibilityLabel("User Prompt")
                }

                Section("Vision Language Model") {
                    Picker("Model", selection: modelBinding(index: index)) {
                        Text("Qwen3-VL 2B Instruct (4-bit)")
                            .tag(WorkspaceVisionModel.qwen3VL2BInstruct4Bit.repositoryID)
                        Text("Qwen3-VL 4B Instruct (4-bit)")
                            .tag(WorkspaceVisionModel.qwen3VL4BInstruct4Bit.repositoryID)
                    }
                    Toggle("Stop at New Line", isOn: $visions[index].stopsAtNewline)
                    statusView(for: visions[index])
                }
                } else {
                    Section("Optical Character Recognition") {
                        Picker("Recognition", selection: ocrRecognitionLevelBinding(index: index)) {
                            Text("Accurate").tag(WorkspaceVisionOCRDefinition.RecognitionLevel.accurate)
                            Text("Fast").tag(WorkspaceVisionOCRDefinition.RecognitionLevel.fast)
                        }
                        TextField(
                            "Languages (Automatic when empty)",
                            text: ocrLanguagesBinding(index: index)
                        )
                        .focused($focusedOCRLanguageVisionID, equals: visionID)
                        .onSubmit { commitOCRLanguages(visionID: visionID) }
                        .onChange(of: focusedOCRLanguageVisionID) { oldValue, newValue in
                            if let oldValue, oldValue != newValue {
                                commitOCRLanguages(visionID: oldValue)
                            }
                        }
                        Picker("Subsampling", selection: ocrSubsamplingBinding(index: index)) {
                            Text("1× (Full Resolution)").tag(1)
                            Text("2×").tag(2)
                            Text("4×").tag(4)
                        }
                        Toggle(
                            "Language Correction",
                            isOn: ocrLanguageCorrectionBinding(index: index)
                        )
                        statusView(for: visions[index])
                    }
                }

                if let analysis = runtimePresenter.analysis(forVisionID: visionID) {
                    Section("Performance") {
                        LabeledContent("Elapsed", value: analysis.elapsedSeconds.formatted(.number.precision(.fractionLength(3))) + " s")
                        if let tokenCount = analysis.generationTokenCount {
                            LabeledContent("Generated Tokens", value: tokenCount.formatted())
                        }
                        if let tokensPerSecond = analysis.tokensPerSecond {
                            LabeledContent(
                                "Generation Speed",
                                value: tokensPerSecond.formatted(.number.precision(.fractionLength(2))) + " tokens/s"
                            )
                        }
                        if let promptTokenCount = analysis.promptTokenCount {
                            LabeledContent("Prompt Tokens", value: promptTokenCount.formatted())
                        }
                        if case .visionLanguageModel = visions[index].definition {
                            memoryView(analysis.memory)
                        }
                    }
                }

                Section {
                    Button("Delete Vision", role: .destructive) { delete(visionID) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(visions[index].name)
            .onDisappear { commitOCRLanguages(visionID: visionID) }
        } else {
            WorkspaceDetailEmptyStateView()
        }
    }

    @ViewBuilder
    private func statusView(for vision: WorkspaceVisionDefinition) -> some View {
        switch runtimePresenter.status(forVisionID: vision.id) {
        case .unavailable:
            LabeledContent("Status", value: "Unavailable")
        case .notDownloaded:
            LabeledContent("Status", value: "Not Downloaded")
        case let .downloading(progress):
            ProgressView(value: progress) { Text("Downloading Model") }
        case .ready:
            LabeledContent("Status", value: "Ready")
        case .analyzing:
            LabeledContent("Status", value: "Analyzing…")
        case let .failed(message):
            LabeledContent("Error") { Text(message).foregroundStyle(.red) }
        }
    }

    @ViewBuilder
    private func memoryView(_ memory: VisionMemoryPresentation) -> some View {
        LabeledContent("MLX Active", value: memory.activeBytes.formatted(.byteCount(style: .memory)))
        LabeledContent("MLX Cache", value: memory.cachedBytes.formatted(.byteCount(style: .memory)))
        LabeledContent("MLX Peak", value: memory.peakActiveBytes.formatted(.byteCount(style: .memory)))
        LabeledContent(
            "Pool Growth",
            value: memory.poolGrowthBytes.formatted(.byteCount(style: .memory))
        )
        LabeledContent("Pool", value: memory.isPoolStable ? "Stable" : "Growing")
    }

    private func sourceBinding(index: Int) -> Binding<String> {
        Binding(
            get: {
                switch visions[index].source {
                case .currentProgramOutput: "program"
                case let .inputDevice(name): "input:\(name)"
                }
            },
            set: { value in
                visions[index].source = value.hasPrefix("input:")
                    ? .inputDevice(name: String(value.dropFirst("input:".count)))
                    : .currentProgramOutput
            }
        )
    }

    private func modelBinding(index: Int) -> Binding<String> {
        Binding(
            get: { visions[index].model.repositoryID },
            set: { repositoryID in
                visions[index].model = WorkspaceVisionModel(repositoryID: repositoryID)
            }
        )
    }

    private func updateIntervalBinding(index: Int) -> Binding<Double> {
        Binding(
            get: { visions[index].updateIntervalSeconds ?? 0 },
            set: { visions[index].updateIntervalSeconds = $0 > 0 ? $0 : nil }
        )
    }

    @ViewBuilder
    private func cropControls(index: Int) -> some View {
        LabeledContent("Crop (%)") {
            Grid(horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    cropField("Top", value: cropBinding(index: index, edge: .top))
                    cropField("Right", value: cropBinding(index: index, edge: .right))
                }
                GridRow {
                    cropField("Bottom", value: cropBinding(index: index, edge: .bottom))
                    cropField("Left", value: cropBinding(index: index, edge: .left))
                }
            }
        }
        Text("The source aspect ratio is preserved; additional crop is centered.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func cropField(_ label: String, value: Binding<Float>) -> some View {
        TextField(label, value: value, format: .number)
            .frame(width: 72)
            .accessibilityLabel("Crop \(label) Percent")
    }

    private enum CropEdge { case top, right, bottom, left }

    private func cropBinding(index: Int, edge: CropEdge) -> Binding<Float> {
        Binding(
            get: {
                switch edge {
                case .top: visions[index].sourceCrop.top
                case .right: visions[index].sourceCrop.right
                case .bottom: visions[index].sourceCrop.bottom
                case .left: visions[index].sourceCrop.left
                }
            },
            set: { newValue in
                let value = min(max(newValue, 0), 100)
                switch edge {
                case .top: visions[index].sourceCrop.top = value
                case .right: visions[index].sourceCrop.right = value
                case .bottom: visions[index].sourceCrop.bottom = value
                case .left: visions[index].sourceCrop.left = value
                }
            }
        )
    }

    private func ocrDefinition(index: Int) -> WorkspaceVisionOCRDefinition {
        if case .opticalCharacterRecognition(let definition) = visions[index].definition {
            return definition
        }
        return .init()
    }

    private func updateOCRDefinition(
        index: Int,
        _ update: (inout WorkspaceVisionOCRDefinition) -> Void
    ) {
        var definition = ocrDefinition(index: index)
        update(&definition)
        visions[index].definition = .opticalCharacterRecognition(definition)
    }

    private func ocrRecognitionLevelBinding(
        index: Int
    ) -> Binding<WorkspaceVisionOCRDefinition.RecognitionLevel> {
        Binding(
            get: { ocrDefinition(index: index).recognitionLevel },
            set: { value in updateOCRDefinition(index: index) { $0.recognitionLevel = value } }
        )
    }

    private func ocrLanguagesBinding(index: Int) -> Binding<String> {
        Binding(
            get: {
                ocrLanguageDrafts[visions[index].id]
                    ?? ocrDefinition(index: index).recognitionLanguages.joined(separator: ", ")
            },
            set: { value in
                ocrLanguageDrafts[visions[index].id] = value
                updateOCRDefinition(index: index) {
                    $0.recognitionLanguages = parsedOCRLanguages(value)
                }
            }
        )
    }

    private func commitOCRLanguages(visionID: String) {
        guard let value = ocrLanguageDrafts.removeValue(forKey: visionID),
              let index = visions.firstIndex(where: { $0.id == visionID }) else { return }
        updateOCRDefinition(index: index) {
            $0.recognitionLanguages = parsedOCRLanguages(value)
        }
    }

    private func parsedOCRLanguages(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func ocrSubsamplingBinding(index: Int) -> Binding<Int> {
        Binding(
            get: { ocrDefinition(index: index).subsamplingRate },
            set: { value in updateOCRDefinition(index: index) { $0.subsamplingRate = value } }
        )
    }

    private func ocrLanguageCorrectionBinding(index: Int) -> Binding<Bool> {
        Binding(
            get: { ocrDefinition(index: index).usesLanguageCorrection },
            set: { value in updateOCRDefinition(index: index) { $0.usesLanguageCorrection = value } }
        )
    }

    private func isBusy(_ status: VisionRuntimePresentationStatus) -> Bool {
        switch status {
        case .downloading, .analyzing: true
        default: false
        }
    }
}
