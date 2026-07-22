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
                beginAddingCompositeStep()
            } label: {
                Label("Add Video Component", systemImage: "plus")
            }
            .accessibilityLabel("Add Video Component")
            .accessibilityIdentifier("addProgramComponentButton")
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
                return NSItemProvider(object: step.name as NSString)
            }
        )
        .accessibilityIdentifier("videoComponentRow-\(step.name)")
    }

    private var selectedVideoComponentID: String? {
        guard case let .some(.videoComponent(id)) = selectedSidebarItem else {
            return nil
        }
        return id
    }

    private var selectedVideoComponentSelection: Binding<String?> {
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

    private func beginAddingCompositeStep() {
        let component = ProgramComponent.inputCameraDevice(InputDeviceComponent())
        proposedVideoComponentName = compositeProgramDefinition.uniqueVideoComponentDisplayName(
            from: component.definition.displayName,
            excluding: nil,
            workspaceInputDevices: workspaceInputDevices
        )
        isShowingAddVideoComponentDialog = true
    }

    func videoComponentNameIsAvailable(_ name: String) -> Bool {
        !name.isEmpty && !compositeProgramDefinition.steps.contains { $0.name == name }
    }

    func addCompositeStep(named name: String) {
        guard videoComponentNameIsAvailable(name) else { return }
        let step = CompositeProgramStep(
            displayName: name,
            component: .inputCameraDevice(InputDeviceComponent())
        )
        compositeProgramDefinition.steps.append(step)
        selectedSidebarItem = .videoComponent(step.id)
        isShowingAddVideoComponentDialog = false
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

    private func compositeStepBinding(index: Int) -> Binding<CompositeProgramStep>? {
        guard compositeProgramDefinition.steps.indices.contains(index) else {
            return nil
        }
        return Binding(
            get: { compositeProgramDefinition.steps[index] },
            set: { compositeProgramDefinition.steps[index] = $0 }
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
    var destinationStepID: String
    @Binding var compositeProgramDefinition: CompositeProgramDefinition
    @Binding var draggedVideoComponentID: String?

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

private extension ProgramComponentDefinition {
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
