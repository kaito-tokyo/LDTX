// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import SwiftUI

extension ProgramContentPane {
    var videoComponentControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if compositeProgramDefinition.steps.isEmpty {
                Text("No video components")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(compositeProgramDefinition.steps.enumerated()), id: \.element.id) { index, step in
                        videoComponentRow(for: step, index: index)
                    }
                }
            }

            Menu {
                ForEach(availableWorkspaceVideoComponents) { component in
                    Button(component.name) {
                        addWorkspaceVideoComponent(component)
                    }
                }
            } label: {
                Label("Add Video Component", systemImage: "plus")
            }
            .disabled(!isProgramStructureEditable || availableWorkspaceVideoComponents.isEmpty)
            .accessibilityLabel("Add Video Component")
            .accessibilityIdentifier("addProgramComponentButton")

            if workspaceVideoComponents.isEmpty {
                Text("Create a Video Component in the sidebar first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if availableWorkspaceVideoComponents.isEmpty {
                Text("All Workspace Video Components are already in this Program.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func videoComponentRow(
        for step: CompositeProgramStep,
        index: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    selectedSidebarItem = .videoComponent(step.id)
                } label: {
                    Label(
                        compositeProgramDefinition.resolvedVideoComponentDisplayName(
                            for: step,
                            workspaceInputDevices: workspaceInputDevices
                        ),
                        systemImage: step.component.definition.videoComponentSystemImage
                    )
                    .lineLimit(1)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                Button {
                    moveCompositeStep(index: index, offset: -1)
                } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
                .labelStyle(.iconOnly)
                .disabled(!isProgramStructureEditable || !canMoveCompositeStep(index: index, offset: -1))
                .accessibilityIdentifier("moveVideoComponentUpButton-\(step.id)")

                Button {
                    moveCompositeStep(index: index, offset: 1)
                } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .labelStyle(.iconOnly)
                .disabled(!isProgramStructureEditable || !canMoveCompositeStep(index: index, offset: 1))
                .accessibilityIdentifier("moveVideoComponentDownButton-\(step.id)")

                Button(role: .destructive) {
                    removeCompositeStep(id: step.id)
                } label: {
                    Label("Remove from Program", systemImage: "minus")
                }
                .labelStyle(.iconOnly)
                .disabled(!isProgramStructureEditable)
                .accessibilityIdentifier("removeVideoComponentButton-\(step.id)")
            }
            .buttonStyle(.borderless)

            destinationControls(index: index)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.background.secondary)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("videoComponentRow-\(step.name)")
    }

    @ViewBuilder
    private func destinationControls(index: Int) -> some View {
        if compositeProgramDefinition.steps.indices.contains(index),
           case .inputCameraDevice = compositeProgramDefinition.steps[index].component {
            HStack(spacing: 8) {
                Text("X")
                ProgramTableFloatField(
                    value: destinationBinding(index: index, keyPath: \.destinationX),
                    unit: "px",
                    fractionDigits: 0
                )
                Text("Y")
                ProgramTableFloatField(
                    value: destinationBinding(index: index, keyPath: \.destinationY),
                    unit: "px",
                    fractionDigits: 0
                )
                Text("Scale")
                ProgramTableFloatField(
                    value: destinationBinding(index: index, keyPath: \.destinationScale),
                    unit: "x",
                    fractionDigits: 2
                )
                Spacer(minLength: 0)
            }
            .font(.callout)
        } else if compositeProgramDefinition.steps.indices.contains(index) {
            Text("Appearance is configured in the Workspace Video Component.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func destinationBinding(
        index: Int,
        keyPath: WritableKeyPath<InputDeviceComponent, Float>
    ) -> Binding<Float> {
        Binding(
            get: {
                guard case .inputCameraDevice(let payload) = compositeProgramDefinition.steps[index].component else {
                    return 0
                }
                return payload[keyPath: keyPath]
            },
            set: { value in
                guard case .inputCameraDevice(var payload) = compositeProgramDefinition.steps[index].component else {
                    return
                }
                payload[keyPath: keyPath] = value
                compositeProgramDefinition.steps[index].component = .inputCameraDevice(payload)
            }
        )
    }

    private var availableWorkspaceVideoComponents: [WorkspaceVideoComponentRecord] {
        let usedNames = Set(compositeProgramDefinition.steps.map(\.name))
        return workspaceVideoComponents.filter { !usedNames.contains($0.name) }
    }

    private var isProgramStructureEditable: Bool {
        windowState.mode == .edit && !windowState.isOperationLocked
    }

    private func addWorkspaceVideoComponent(_ resource: WorkspaceVideoComponentRecord) {
        guard !compositeProgramDefinition.steps.contains(where: { $0.name == resource.name }) else { return }
        let step = CompositeProgramStep(
            displayName: resource.name,
            component: resource.component
        )
        compositeProgramDefinition.steps.append(step)
    }

    private func canMoveCompositeStep(index: Int, offset: Int) -> Bool {
        guard compositeProgramDefinition.steps.indices.contains(index) else { return false }
        return compositeProgramDefinition.steps.indices.contains(index + offset)
    }

    private func moveCompositeStep(index: Int, offset: Int) {
        guard compositeProgramDefinition.steps.indices.contains(index) else { return }
        let destination = index + offset
        guard compositeProgramDefinition.steps.indices.contains(destination) else { return }
        withAnimation(.snappy(duration: 0.16)) {
            compositeProgramDefinition.steps.swapAt(index, destination)
        }
    }

    private func removeCompositeStep(id: String) {
        compositeProgramDefinition.steps.removeAll { $0.id == id }
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
