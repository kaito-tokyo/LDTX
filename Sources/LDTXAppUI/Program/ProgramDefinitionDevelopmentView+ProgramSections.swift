// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import SwiftUI
import UniformTypeIdentifiers

extension ProgramDefinitionDevelopmentView {
    var compositeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(composite.steps.indices, id: \.self) { index in
                if let step = compositeStepBinding(index: index) {
                    DisclosureGroup(
                        isExpanded: compositeStepExpansionBinding(for: step.wrappedValue.id),
                        content: {
                            VStack(alignment: .leading, spacing: 8) {
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

                                componentParameterControls(for: step)

                                HStack {
                                    Spacer()

                                    Button {
                                        deleteCompositeStep(index: index)
                                    } label: {
                                        Label("Delete", systemImage: "minus.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .padding(.top, 8)
                        },
                        label: {
                            HStack {
                                Text(step.wrappedValue.component.definition.displayName)
                                    .lineLimit(1)

                                Spacer()

                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, height: 20)
                                    .help("Drag to reorder")
                            }
                        }
                    )
                    .padding(.vertical, 6)
                    .onDrag {
                        draggedVideoComponentID = step.wrappedValue.id
                        return NSItemProvider(object: step.wrappedValue.id.uuidString as NSString)
                    } preview: {
                        Color.clear
                            .frame(width: 1, height: 1)
                    }
                    .onDrop(
                        of: [UTType.text],
                        delegate: ProgramVideoComponentDropDelegate(
                            destinationStepID: step.wrappedValue.id,
                            composite: $composite,
                            draggedVideoComponentID: $draggedVideoComponentID
                        )
                    )
                    .accessibilityIdentifier("videoComponentDisclosure-\(step.wrappedValue.id.uuidString)")
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

    private func compositeStepExpansionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedVideoComponentIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedVideoComponentIDs.insert(id)
                } else {
                    expandedVideoComponentIDs.remove(id)
                }
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

private struct ProgramVideoComponentDropDelegate: DropDelegate {
    var destinationStepID: UUID
    @Binding var composite: CompositeProgramDefinition
    @Binding var draggedVideoComponentID: UUID?

    func dropEntered(info _: DropInfo) {
        guard let draggedVideoComponentID,
              draggedVideoComponentID != destinationStepID,
              let sourceIndex = composite.steps.firstIndex(where: { $0.id == draggedVideoComponentID }),
              let destinationIndex = composite.steps.firstIndex(where: { $0.id == destinationStepID })
        else {
            return
        }

        if composite.steps[destinationIndex].id != draggedVideoComponentID {
            withAnimation(.snappy(duration: 0.16)) {
                composite.steps.move(
                    fromOffsets: IndexSet(integer: sourceIndex),
                    toOffset: sourceIndex < destinationIndex ? destinationIndex + 1 : destinationIndex
                )
            }
        }
    }

    func performDrop(info _: DropInfo) -> Bool {
        draggedVideoComponentID = nil
        return true
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info _: DropInfo) {}
}
