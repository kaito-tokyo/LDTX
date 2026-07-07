// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
import LDTXYouTube
import SwiftUI

public struct ProgramDefinitionSaveCommand {
    public var isEnabled: Bool
    public var perform: () -> Void

    public init(isEnabled: Bool, perform: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.perform = perform
    }
}

struct WorkspaceDetailPane: View {
    @Binding var selectedSidebarItem: WorkspaceSidebarItem?
    @Binding var compositeProgramDefinition: CompositeProgramDefinition
    var outputCanvas: OutputCanvasModel
    var workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator
    @Binding var workspaceInputDevices: [WorkspaceInputDeviceRecord]
    var cameras: [InputPhysicalDeviceOption]
    var audioDevices: [InputPhysicalDeviceOption]
    var refreshCameras: () -> Void
    var deleteWorkspaceInputDevice: (String) -> Void
    var workspaceInputDeviceOptions: [WorkspaceInputDeviceRecord]
    var outputDestination: OutputDestinationModel
    var existingBroadcasts: [YouTubeLiveBroadcast]
    var isLoadingBroadcasts: Bool
    var isConnectingBroadcast: Bool
    var isStreamingToYouTube: Bool
    var isRecording: Bool
    var canSelectYouTubeBroadcast: Bool
    var localOutputStatus: String
    var refreshExistingBroadcasts: () -> Void
    var manageYouTubeBroadcasts: () -> Void
    var chooseLocalOutputDirectory: () -> Void

    var body: some View {
        switch detailContentSelection {
        case .streamSettings:
            WorkspaceStreamStatsDetailPane(
                outputCanvas: outputCanvas,
                outputDestination: outputDestination,
                existingBroadcasts: existingBroadcasts,
                isLoadingBroadcasts: isLoadingBroadcasts,
                isConnectingBroadcast: isConnectingBroadcast,
                isStreamingToYouTube: isStreamingToYouTube,
                isRecording: isRecording,
                canSelectYouTubeBroadcast: canSelectYouTubeBroadcast,
                localOutputStatus: localOutputStatus,
                refreshExistingBroadcasts: refreshExistingBroadcasts,
                manageYouTubeBroadcasts: manageYouTubeBroadcasts,
                chooseLocalOutputDirectory: chooseLocalOutputDirectory
            )
        case .inputDevice:
            InputDeviceDetailPane(
                inputDevices: $workspaceInputDevices,
                selectedInputDeviceID: selectedInputDeviceID,
                workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
                cameras: cameras,
                audioDevices: audioDevices,
                refreshPhysicalDevices: refreshCameras,
                deleteInputDevice: deleteWorkspaceInputDevice
            )
        case .videoComponent:
            VideoComponentDetailPane(
                compositeProgramDefinition: $compositeProgramDefinition,
                selectedSidebarItem: $selectedSidebarItem,
                workspaceInputDevices: workspaceInputDeviceOptions
            )
        case .empty:
            WorkspaceDetailEmptyStateView()
        }
    }

    private var detailContentSelection: WorkspaceDetailContentSelection {
        if selectedSidebarItem == .streamSettings {
            return .streamSettings
        }
        if selectedInputDeviceExists {
            return .inputDevice
        }
        if selectedVideoComponentExists {
            return .videoComponent
        }
        return .empty
    }

    private var selectedInputDeviceExists: Bool {
        guard let selectedID = selectedInputDeviceID.wrappedValue else {
            return false
        }
        return workspaceInputDevices.contains { $0.id == selectedID }
    }

    private var selectedInputDeviceID: Binding<String?> {
        Binding(
            get: {
                if case let .some(.inputDevice(id)) = selectedSidebarItem {
                    return id
                }
                return nil
            },
            set: { newValue in
                guard let newValue,
                      workspaceInputDevices.contains(where: { $0.id == newValue }) else {
                    selectedSidebarItem = .streamSettings
                    return
                }
                selectedSidebarItem = .inputDevice(newValue)
            }
        )
    }

    private var selectedVideoComponentExists: Bool {
        guard case let .some(.videoComponent(id)) = selectedSidebarItem else {
            return false
        }
        return compositeProgramDefinition.steps.contains { $0.id == id }
    }
}

private enum WorkspaceDetailContentSelection {
    case streamSettings
    case inputDevice
    case videoComponent
    case empty
}

#if DEBUG
#Preview("Workspace Detail Empty") {
    WorkspaceDetailPaneEmptyPreviewHost()
        .frame(width: 560, height: 760)
}

#Preview("Workspace Detail Input Device") {
    WorkspaceDetailPaneInputPreviewHost()
        .frame(width: 560, height: 520)
}

private struct WorkspaceDetailPaneEmptyPreviewHost: View {
    @State private var selectedSidebarItem = LDTXAppUIPreviewFixtures.selectedSidebarItem
    @State private var compositeProgramDefinition = LDTXAppUIPreviewFixtures.compositeProgramDefinition
    @State private var workspaceInputDevices = LDTXAppUIPreviewFixtures.workspaceInputDevices

    var body: some View {
        WorkspaceDetailPane(
            selectedSidebarItem: $selectedSidebarItem,
            compositeProgramDefinition: $compositeProgramDefinition,
            outputCanvas: LDTXAppUIPreviewFixtures.makeOutputCanvasModel(),
            workspaceCaptureSessionCoordinator: LDTXAppUIPreviewFixtures.makeWorkspaceCaptureSessionCoordinator(),
            workspaceInputDevices: $workspaceInputDevices,
            cameras: LDTXAppUIPreviewFixtures.cameras,
            audioDevices: LDTXAppUIPreviewFixtures.audioDevices,
            refreshCameras: {},
            deleteWorkspaceInputDevice: { _ in },
            workspaceInputDeviceOptions: workspaceInputDevices,
            outputDestination: LDTXAppUIPreviewFixtures.makeOutputDestinationModel(),
            existingBroadcasts: LDTXAppUIPreviewFixtures.existingBroadcasts,
            isLoadingBroadcasts: false,
            isConnectingBroadcast: false,
            isStreamingToYouTube: false,
            isRecording: false,
            canSelectYouTubeBroadcast: true,
            localOutputStatus: LDTXAppUIPreviewFixtures.localOutputStatus,
            refreshExistingBroadcasts: {},
            manageYouTubeBroadcasts: {},
            chooseLocalOutputDirectory: {}
        )
    }
}

private struct WorkspaceDetailPaneInputPreviewHost: View {
    @State private var selectedSidebarItem: WorkspaceSidebarItem? = .inputDevice("workspace-video-1")
    @State private var compositeProgramDefinition = LDTXAppUIPreviewFixtures.compositeProgramDefinition
    @State private var workspaceInputDevices = LDTXAppUIPreviewFixtures.workspaceInputDevices

    var body: some View {
        WorkspaceDetailPane(
            selectedSidebarItem: $selectedSidebarItem,
            compositeProgramDefinition: $compositeProgramDefinition,
            outputCanvas: LDTXAppUIPreviewFixtures.makeOutputCanvasModel(),
            workspaceCaptureSessionCoordinator: LDTXAppUIPreviewFixtures.makeWorkspaceCaptureSessionCoordinator(),
            workspaceInputDevices: $workspaceInputDevices,
            cameras: LDTXAppUIPreviewFixtures.cameras,
            audioDevices: LDTXAppUIPreviewFixtures.audioDevices,
            refreshCameras: {},
            deleteWorkspaceInputDevice: { _ in },
            workspaceInputDeviceOptions: workspaceInputDevices,
            outputDestination: LDTXAppUIPreviewFixtures.makeOutputDestinationModel(),
            existingBroadcasts: LDTXAppUIPreviewFixtures.existingBroadcasts,
            isLoadingBroadcasts: false,
            isConnectingBroadcast: false,
            isStreamingToYouTube: false,
            isRecording: false,
            canSelectYouTubeBroadcast: true,
            localOutputStatus: LDTXAppUIPreviewFixtures.localOutputStatus,
            refreshExistingBroadcasts: {},
            manageYouTubeBroadcasts: {},
            chooseLocalOutputDirectory: {}
        )
    }
}
#endif
