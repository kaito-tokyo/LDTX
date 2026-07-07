// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import SwiftUI

extension ProgramDefinitionDevelopmentView {
    var compositeControls: some View {
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

    var audioChannelControls: some View {
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
        composite.steps.append(CompositeProgramStep(component: component))
    }

    private func addAudioChannel() {
        let component = ProgramAudioChannelComponent.inputAudioDevice(InputAudioDeviceComponent())
        composite.audioChannels.append(ProgramAudioChannel(component: component))
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

}
