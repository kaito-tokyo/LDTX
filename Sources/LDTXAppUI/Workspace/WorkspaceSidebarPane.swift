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
    @Binding private var automations: [WorkspaceAutomationDefinition]
    private let isInputDeviceEditingEnabled: Bool
    private let featureAvailability: WorkspaceFeatureAvailability

    static func showsMuteControl(for kind: ProgramInputDeviceKind) -> Bool {
        kind.supportsProgramVideoMute
    }
    static func isMuteControlEnabled(for kind: ProgramInputDeviceKind, isStructuralEditingEnabled _: Bool) -> Bool {
        kind.supportsProgramVideoMute
    }

    public init(
        selectedSidebarItem: Binding<WorkspaceSidebarItem?>,
        workspaceInputDevices: Binding<[WorkspaceInputDeviceRecord]>,
        programPreferences: Binding<ProgramPreferences>,
        visions: Binding<[WorkspaceVisionDefinition]>,
        automations: Binding<[WorkspaceAutomationDefinition]>,
        isInputDeviceEditingEnabled: Bool = true,
        featureAvailability: WorkspaceFeatureAvailability = .all
    ) {
        _selectedSidebarItem = selectedSidebarItem
        _inputDevices = workspaceInputDevices
        _preferences = programPreferences
        _visions = visions
        _automations = automations
        self.isInputDeviceEditingEnabled = isInputDeviceEditingEnabled
        self.featureAvailability = featureAvailability
    }

    public var body: some View {
        List(selection: selectedListItem) {
            Label("Output", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(.primary).tag(WorkspaceSidebarItem.streamSettings)
            InputDevicesSidebarSection(
                inputDevices: $inputDevices, preferences: $preferences,
                selectedSidebarItem: $selectedSidebarItem, visions: visions,
                automations: automations, isEditingEnabled: isInputDeviceEditingEnabled
            )
            VisionSidebarSection(
                visions: $visions, selectedSidebarItem: $selectedSidebarItem,
                inputDevices: inputDevices, automations: automations,
                isEnabled: featureAvailability.supportsVision
            )
            AutomationSidebarSection(
                automations: $automations, selectedSidebarItem: $selectedSidebarItem,
                inputDevices: inputDevices, visions: visions,
                isEnabled: featureAvailability.supportsAutomation
            )
        }
        .listStyle(.sidebar)
        .navigationTitle("Workspace")
    }

    private var selectedListItem: Binding<WorkspaceSidebarItem?> {
        Binding(
            get: {
                switch selectedSidebarItem {
                case .some(.streamSettings), .some(.inputDevice), .some(.vision), .some(.automation):
                    selectedSidebarItem
                default: nil
                }
            },
            set: { selectedSidebarItem = $0 }
        )
    }
}
