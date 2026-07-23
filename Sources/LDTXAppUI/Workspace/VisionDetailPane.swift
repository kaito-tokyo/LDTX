// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXInternalProtocols
import LDTXWorkspace
import SwiftUI

struct VisionDetailPane: View {
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

                Section("Model") {
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
                    Picker("Model", selection: modelBinding(index: index)) {
                        Text("Qwen3-VL 2B Instruct (4-bit)")
                            .tag(WorkspaceVisionModel.qwen3VL2BInstruct4Bit.repositoryID)
                        Text("Qwen3-VL 4B Instruct (4-bit)")
                            .tag(WorkspaceVisionModel.qwen3VL4BInstruct4Bit.repositoryID)
                    }
                    Picker("Update", selection: updateIntervalBinding(index: index)) {
                        Text("Manual").tag(0.0)
                        Text("Every 0.5 Seconds").tag(0.5)
                        Text("Every Second").tag(1.0)
                        Text("Every 2 Seconds").tag(2.0)
                        Text("Every 5 Seconds").tag(5.0)
                        Text("Every 10 Seconds").tag(10.0)
                    }
                    Toggle("Stop at New Line", isOn: $visions[index].stopsAtNewline)
                    statusView(for: visions[index])
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
                        memoryView(analysis.memory)
                    }
                }

                Section {
                    Button("Delete Vision", role: .destructive) { delete(visionID) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(visions[index].name)
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

    private func isBusy(_ status: VisionRuntimePresentationStatus) -> Bool {
        switch status {
        case .downloading, .analyzing: true
        default: false
        }
    }
}
