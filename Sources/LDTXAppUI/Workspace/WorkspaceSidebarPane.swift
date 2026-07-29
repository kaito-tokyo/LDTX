// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import SwiftUI

public struct WorkspaceSidebarPane: View {
    @Binding private var selectedSidebarItem: WorkspaceSidebarItem?
    @Binding private var inputDevices: [WorkspaceInputDeviceRecord]
    @Binding private var preferences: ProgramPreferences
    @Binding private var visions: [WorkspaceVisionDefinition]
    @Binding private var videoComponents: [WorkspaceVideoComponentRecord]
    private let windowState: WorkspaceWindowState
    private let featureAvailability: WorkspaceFeatureAvailability
    private let cameras: [InputPhysicalDeviceOption]
    private let audioDevices: [InputPhysicalDeviceOption]

    static func showsMuteControl(for kind: ProgramInputDeviceKind) -> Bool {
        kind == .video || kind == .audio
    }
    static func isMuteControlEnabled(for kind: ProgramInputDeviceKind) -> Bool {
        kind == .video || kind == .audio
    }

    public init(
        selectedSidebarItem: Binding<WorkspaceSidebarItem?>,
        workspaceInputDevices: Binding<[WorkspaceInputDeviceRecord]>,
        programPreferences: Binding<ProgramPreferences>,
        visions: Binding<[WorkspaceVisionDefinition]>,
        videoComponents: Binding<[WorkspaceVideoComponentRecord]> = .constant([]),
        windowState: WorkspaceWindowState = WorkspaceWindowState(
            mode: .edit,
            outputSessionState: .idle,
            isOperationLocked: false
        ),
        featureAvailability: WorkspaceFeatureAvailability = .all,
        cameras: [InputPhysicalDeviceOption] = [],
        audioDevices: [InputPhysicalDeviceOption] = []
    ) {
        _selectedSidebarItem = selectedSidebarItem
        _inputDevices = workspaceInputDevices
        _preferences = programPreferences
        _visions = visions
        _videoComponents = videoComponents
        self.windowState = windowState
        self.featureAvailability = featureAvailability
        self.cameras = cameras
        self.audioDevices = audioDevices
    }

    public var body: some View {
        List(selection: selectedListItem) {
            Label("Output", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(.primary).tag(WorkspaceSidebarItem.output)
            Label("Canvas", systemImage: "rectangle.on.rectangle")
                .foregroundStyle(.primary).tag(WorkspaceSidebarItem.canvas)
            InputDevicesSidebarSection(
                inputDevices: $inputDevices, preferences: $preferences,
                selectedSidebarItem: $selectedSidebarItem, visions: visions,
                videoComponents: videoComponents,
                cameras: cameras, audioDevices: audioDevices,
                windowState: windowState
            )
            VideoComponentsSidebarSection(
                videoComponents: $videoComponents,
                selectedSidebarItem: $selectedSidebarItem,
                inputDevices: inputDevices,
                visions: visions,
                windowState: windowState
            )
            VisionSidebarSection(
                visions: $visions, selectedSidebarItem: $selectedSidebarItem,
                inputDevices: inputDevices, videoComponents: videoComponents,
                featureAvailability: featureAvailability,
                windowState: windowState
            )
        }
        .listStyle(.sidebar)
        .navigationTitle("Workspace")
    }

    private var selectedListItem: Binding<WorkspaceSidebarItem?> {
        if isRenderingPipelineEditable {
            return $selectedSidebarItem
        }
        return Binding(
            get: {
                switch selectedSidebarItem {
                case .some(.inputDevice), .some(.videoComponent)
                    where !isRenderingPipelineEditable:
                    .output
                case .some(.output), .some(.canvas), .some(.inputDevice), .some(.videoComponent),
                    .some(.vision):
                    selectedSidebarItem
                default: nil
                }
            },
            set: { newSelection in
                switch newSelection {
                case .some(.inputDevice), .some(.videoComponent)
                    where !isRenderingPipelineEditable:
                    return
                default:
                    selectedSidebarItem = newSelection
                }
            }
        )
    }

    /// Output mode freezes only resources that form the render pipeline.
    /// Vision remains selectable because it observes the pipeline without
    /// rebuilding it.
    private var isRenderingPipelineEditable: Bool {
        windowState.mode == .edit && !windowState.isOperationLocked
    }
}
