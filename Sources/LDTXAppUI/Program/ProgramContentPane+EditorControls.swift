// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import SwiftUI

extension ProgramContentPane {
    var videoComponentControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if videoLayers.isEmpty {
                Text("No video layers")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(videoLayers.enumerated()), id: \.element.id) { index, layer in
                        videoLayerRow(for: layer, index: index)
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
                Label("Add Video Layer", systemImage: "plus")
            }
            .disabled(!isProgramStructureEditable || availableWorkspaceVideoComponents.isEmpty)
            .accessibilityLabel("Add Video Layer")
            .accessibilityIdentifier("addProgramComponentButton")

            if workspaceVideoComponents.isEmpty {
                Text("Create a Video Component in the sidebar first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if availableWorkspaceVideoComponents.isEmpty {
                Text("All Workspace Video Components already have a Video Layer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func videoLayerRow(
        for layer: VideoLayerPreference,
        index: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    selectedSidebarItem = .videoComponent(layer.componentName)
                } label: {
                    Label(
                        layer.componentName,
                        systemImage: componentDefinition(named: layer.componentName)?.videoComponentSystemImage ?? "square.stack"
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
                .accessibilityIdentifier("moveVideoComponentUpButton-\(layer.id)")

                Button {
                    moveCompositeStep(index: index, offset: 1)
                } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .labelStyle(.iconOnly)
                .disabled(!isProgramStructureEditable || !canMoveCompositeStep(index: index, offset: 1))
                .accessibilityIdentifier("moveVideoComponentDownButton-\(layer.id)")

                Button(role: .destructive) {
                    removeVideoLayer(id: layer.id)
                } label: {
                    Label("Remove from Program", systemImage: "minus")
                }
                .labelStyle(.iconOnly)
                .disabled(!isProgramStructureEditable)
                .accessibilityIdentifier("removeVideoComponentButton-\(layer.id)")
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
        .accessibilityIdentifier("videoComponentRow-\(layer.componentName)")
    }

    @ViewBuilder
    private func destinationControls(index: Int) -> some View {
        if videoLayers.indices.contains(index),
           layerSupportsDestination(videoLayers[index]) {
            HStack(spacing: 8) {
                Text("X")
                ProgramTableFloatField(
                    value: layerDestinationBinding(index: index, keyPath: \.destinationX),
                    unit: "px",
                    fractionDigits: 0
                )
                Text("Y")
                ProgramTableFloatField(
                    value: layerDestinationBinding(index: index, keyPath: \.destinationY),
                    unit: "px",
                    fractionDigits: 0
                )
                Text("Scale")
                ProgramTableFloatField(
                    value: layerDestinationBinding(index: index, keyPath: \.destinationScale),
                    unit: "x",
                    fractionDigits: 2
                )
                Spacer(minLength: 0)
            }
            .font(.callout)
        }
    }

    private func layerDestinationBinding(
        index: Int,
        keyPath: WritableKeyPath<VideoLayerPreference, Float>
    ) -> Binding<Float> {
        Binding(
            get: { videoLayers[index][keyPath: keyPath] },
            set: { value in
                updateVideoLayers { $0[index][keyPath: keyPath] = value }
                applyVideoLayerPreferencesToWorkingComposite()
            }
        )
    }

    private var availableWorkspaceVideoComponents: [WorkspaceVideoComponentRecord] {
        let usedNames = Set(videoLayers.map(\.componentName))
        return workspaceVideoComponents.filter { !usedNames.contains($0.name) }
    }

    private var isProgramStructureEditable: Bool {
        windowState.mode == .edit && !windowState.isOperationLocked
    }

    private func addWorkspaceVideoComponent(_ resource: WorkspaceVideoComponentRecord) {
        guard !videoLayers.contains(where: { $0.componentName == resource.name }) else { return }
        updateVideoLayers { $0.append(VideoLayerPreference(componentName: resource.name)) }
        let step = CompositeProgramStep(
            displayName: resource.name,
            component: resource.component
        )
        compositeProgramDefinition.steps.append(step)
        applyVideoLayerPreferencesToWorkingComposite()
    }

    private func canMoveCompositeStep(index: Int, offset: Int) -> Bool {
        guard videoLayers.indices.contains(index) else { return false }
        return videoLayers.indices.contains(index + offset)
    }

    private func moveCompositeStep(index: Int, offset: Int) {
        guard videoLayers.indices.contains(index) else { return }
        let destination = index + offset
        guard videoLayers.indices.contains(destination) else { return }
        withAnimation(.snappy(duration: 0.16)) {
            updateVideoLayers { $0.swapAt(index, destination) }
            applyVideoLayerPreferencesToWorkingComposite()
        }
    }

    private func removeVideoLayer(id: String) {
        updateVideoLayers { $0.removeAll { $0.id == id } }
        compositeProgramDefinition.steps.removeAll { $0.id == id }
    }

    private func componentDefinition(named name: String) -> ProgramComponentDefinition? {
        workspaceVideoComponents.first(where: { $0.name == name })?.component.definition
    }

    private func layerSupportsDestination(_ layer: VideoLayerPreference) -> Bool {
        switch componentDefinition(named: layer.componentName) {
        case .inputCameraDevice, .clock:
            true
        case .fillSolidColor, .fillLinearGradient, .fillRadialGradient, .fillConicGradient, .testPattern,
             .none:
            false
        }
    }

    private func applyVideoLayerPreferencesToWorkingComposite() {
        compositeProgramDefinition = WorkspaceVideoComponentResolver.applying(
            workspaceVideoComponents,
            layers: videoLayers,
            to: compositeProgramDefinition
        )
    }

    private var videoLayerProgramName: String {
        selectedProgramDefinitionName ?? selectedProgramDefinitionRecord?.name ?? "New Program"
    }

    private var videoLayers: [VideoLayerPreference] {
        programPreferences.videoLayers(forProgramNamed: videoLayerProgramName)
    }

    private func updateVideoLayers(_ mutation: (inout [VideoLayerPreference]) -> Void) {
        var layers = videoLayers
        mutation(&layers)
        programPreferences.setVideoLayers(layers, forProgramNamed: videoLayerProgramName)
    }
}

private extension ProgramComponentDefinition {
    var videoComponentSystemImage: String {
        switch self {
        case .inputCameraDevice:
            return "video"
        case .fillSolidColor, .fillLinearGradient, .fillRadialGradient, .fillConicGradient:
            return "square.fill"
        case .clock:
            return "clock"
        case .testPattern:
            return "checkerboard.rectangle"
        }
    }
}
