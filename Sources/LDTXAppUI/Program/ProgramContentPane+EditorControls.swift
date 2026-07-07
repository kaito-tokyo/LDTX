// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import SwiftUI
import UniformTypeIdentifiers

extension ProgramContentPane {
    var videoComponentControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            List(selection: selectedVideoComponentSelection) {
                if compositeProgramDefinition.steps.isEmpty {
                    Text("No video components")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(compositeProgramDefinition.steps.enumerated()), id: \.element.id) { index, step in
                        videoComponentRow(
                            for: step,
                            canMoveUp: canMoveCompositeStep(index: index, offset: -1),
                            canMoveDown: canMoveCompositeStep(index: index, offset: 1),
                            moveUp: { moveCompositeStep(index: index, offset: -1) },
                            moveDown: { moveCompositeStep(index: index, offset: 1) }
                        )
                        .tag(step.id)
                        .onDrop(
                            of: [UTType.text],
                            delegate: ProgramVideoComponentDropDelegate(
                                destinationStepID: step.id,
                                compositeProgramDefinition: $compositeProgramDefinition,
                                draggedVideoComponentID: $draggedVideoComponentID
                            )
                        )
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: videoComponentListHeight)

            Button {
                addCompositeStep()
            } label: {
                Label("Add Video Component", systemImage: "plus")
            }
            .accessibilityLabel("Add Video Component")
            .accessibilityIdentifier("addProgramComponentButton")
        }
    }

    var audioChannelDefinitionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(compositeProgramDefinition.audioChannels.indices, id: \.self) { index in
                if let channel = audioChannelBinding(index: index) {
                    ProgramAudioChannelDefinitionEditor(
                        channel: channel,
                        workspaceInputDevices: workspaceInputDevices,
                        canMoveUp: canMoveAudioChannel(index: index, offset: -1),
                        canMoveDown: canMoveAudioChannel(index: index, offset: 1),
                        moveUp: { moveAudioChannel(index: index, offset: -1) },
                        moveDown: { moveAudioChannel(index: index, offset: 1) },
                        delete: { deleteAudioChannel(index: index) }
                    )
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

    private func videoComponentRow(
        for step: CompositeProgramStep,
        canMoveUp: Bool,
        canMoveDown: Bool,
        moveUp: @escaping () -> Void,
        moveDown: @escaping () -> Void
    ) -> some View {
        VideoComponentListRow(
            step: step,
            title: compositeProgramDefinition.resolvedVideoComponentDisplayName(
                for: step,
                workspaceInputDevices: workspaceInputDevices
            ),
            canMoveUp: canMoveUp,
            canMoveDown: canMoveDown,
            moveUp: moveUp,
            moveDown: moveDown,
            beginDrag: {
                draggedVideoComponentID = step.id
                return NSItemProvider(object: step.id.uuidString as NSString)
            }
        )
        .accessibilityIdentifier("videoComponentRow-\(step.id.uuidString)")
    }

    private var selectedVideoComponentID: UUID? {
        guard case let .some(.videoComponent(id)) = selectedSidebarItem else {
            return nil
        }
        return id
    }

    private var selectedVideoComponentSelection: Binding<UUID?> {
        Binding(
            get: { selectedVideoComponentID },
            set: { newValue in
                selectedSidebarItem = newValue.map(WorkspaceSidebarItem.videoComponent)
            }
        )
    }

    private var videoComponentListHeight: CGFloat {
        let visibleRows = min(max(compositeProgramDefinition.steps.count, 3), 8)
        return CGFloat(visibleRows * 28 + 24)
    }

    private func addCompositeStep() {
        let step = CompositeProgramStep(component: .inputCameraDevice(InputDeviceComponent()))
        compositeProgramDefinition.steps.append(step)
        selectedSidebarItem = .videoComponent(step.id)
    }

    private func canMoveCompositeStep(index: Int, offset: Int) -> Bool {
        guard compositeProgramDefinition.steps.indices.contains(index) else {
            return false
        }
        return compositeProgramDefinition.steps.indices.contains(index + offset)
    }

    private func moveCompositeStep(index: Int, offset: Int) {
        guard compositeProgramDefinition.steps.indices.contains(index) else {
            return
        }
        let destination = index + offset
        guard compositeProgramDefinition.steps.indices.contains(destination) else {
            return
        }
        withAnimation(.snappy(duration: 0.16)) {
            compositeProgramDefinition.steps.swapAt(index, destination)
        }
    }

    private func addAudioChannel() {
        compositeProgramDefinition.audioChannels.append(
            ProgramAudioChannel(component: .inputAudioDevice(InputAudioDeviceComponent()))
        )
    }

    private func deleteAudioChannel(index: Int) {
        guard compositeProgramDefinition.audioChannels.indices.contains(index) else {
            return
        }
        compositeProgramDefinition.audioChannels.remove(at: index)
    }

    private func canMoveAudioChannel(index: Int, offset: Int) -> Bool {
        guard compositeProgramDefinition.audioChannels.indices.contains(index) else {
            return false
        }
        return compositeProgramDefinition.audioChannels.indices.contains(index + offset)
    }

    private func moveAudioChannel(index: Int, offset: Int) {
        guard compositeProgramDefinition.audioChannels.indices.contains(index) else {
            return
        }
        let destination = index + offset
        guard compositeProgramDefinition.audioChannels.indices.contains(destination) else {
            return
        }
        compositeProgramDefinition.audioChannels.swapAt(index, destination)
    }

    private func compositeStepBinding(index: Int) -> Binding<CompositeProgramStep>? {
        guard compositeProgramDefinition.steps.indices.contains(index) else {
            return nil
        }
        return Binding(
            get: { compositeProgramDefinition.steps[index] },
            set: { compositeProgramDefinition.steps[index] = $0 }
        )
    }

    private func audioChannelBinding(index: Int) -> Binding<ProgramAudioChannel>? {
        guard compositeProgramDefinition.audioChannels.indices.contains(index) else {
            return nil
        }
        return Binding(
            get: { compositeProgramDefinition.audioChannels[index] },
            set: { compositeProgramDefinition.audioChannels[index] = $0 }
        )
    }
}

private struct VideoComponentListRow: View {
    var step: CompositeProgramStep
    var title: String
    var canMoveUp: Bool
    var canMoveDown: Bool
    var moveUp: () -> Void
    var moveDown: () -> Void
    var beginDrag: () -> NSItemProvider

    var body: some View {
        Label {
            Text(title)
                .lineLimit(1)
        } icon: {
            Image(systemName: step.component.definition.videoComponentSystemImage)
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Move Up", action: moveUp)
                .disabled(!canMoveUp)
            Button("Move Down", action: moveDown)
                .disabled(!canMoveDown)
        }
        .onDrag(beginDrag) {
            Color.clear
                .frame(width: 1, height: 1)
        }
    }
}

private struct ProgramVideoComponentDropDelegate: DropDelegate {
    var destinationStepID: UUID
    @Binding var compositeProgramDefinition: CompositeProgramDefinition
    @Binding var draggedVideoComponentID: UUID?

    func dropEntered(info _: DropInfo) {
        guard let draggedVideoComponentID,
              draggedVideoComponentID != destinationStepID,
              let sourceIndex = compositeProgramDefinition.steps.firstIndex(where: { $0.id == draggedVideoComponentID }),
              let destinationIndex = compositeProgramDefinition.steps.firstIndex(where: { $0.id == destinationStepID })
        else {
            return
        }

        if compositeProgramDefinition.steps[destinationIndex].id != draggedVideoComponentID {
            withAnimation(.snappy(duration: 0.16)) {
                compositeProgramDefinition.steps.move(
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
}

private extension BuiltInProgramDefinition {
    var videoComponentSystemImage: String {
        switch self {
        case .inputCameraDevice:
            return "video"
        case .fillSolidColor, .fillLinearGradient, .fillRadialGradient, .fillConicGradient:
            return "square.fill"
        case .testPattern:
            return "checkerboard.rectangle"
        }
    }
}
