// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXProgramRuntime
import LDTXInternalProtocols
import LDTXWorkspace
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
    @Binding var visions: [WorkspaceVisionDefinition]
    @Binding var videoComponents: [WorkspaceVideoComponentRecord]
    @Binding var videoPTSMasterInputDeviceID: String?
    var visionRuntimePresenter: any VisionRuntimePresenting
    var backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory? = nil
    var analyzeVision: (WorkspaceVisionDefinition) -> Void
    var cameras: [InputPhysicalDeviceOption]
    var audioDevices: [InputPhysicalDeviceOption]
    var refreshCameras: () -> Void
    var deleteWorkspaceInputDevice: (String) -> Void
    var deleteWorkspaceVideoComponent: (String) -> Void = { _ in }
    var deleteWorkspaceVision: (String) -> Void = { _ in }
    var workspaceInputDeviceOptions: [WorkspaceInputDeviceRecord]
    var outputDestination: AppOutputSettings
    var selectedProgramName: String? = nil
    var windowState: WorkspaceWindowState = WorkspaceWindowState(
        mode: .edit,
        outputSessionState: .idle,
        isOperationLocked: false
    )
    var isOutputSessionStartEnabled: Bool = false
    var outputSessionStartLabel: String = "Start Output"
    var showsOutputSessionControls: Bool = true
    var existingBroadcasts: [LiveBroadcastSummary]
    var isLoadingBroadcasts: Bool
    var featureAvailability: WorkspaceFeatureAvailability = .all
    var refreshExistingBroadcasts: () -> Void
    var manageYouTubeBroadcasts: () -> Void
    var chooseOutputDirectory: () -> URL? = { nil }
    var applyOutputSettings: (AppOutputSettings) -> Void = { _ in }
    var captureFrame: () -> Void = {}
    var openScreenshotsDirectory: () -> Void = {}
    var startOutputSession: () -> Void = {}
    var pauseOutputSession: () -> Void = {}
    var stopOutputSession: () -> Void = {}
    var resetSession: () -> Void = {}

    var body: some View {
        switch detailContentSelection {
        case .streamSettings:
            OutputOrchestrationDetailPane(
                selectedProgramName: selectedProgramName,
                windowState: windowState,
                isOutputSessionStartEnabled: isOutputSessionStartEnabled,
                outputSessionStartLabel: outputSessionStartLabel,
                showsSessionControls: showsOutputSessionControls,
                outputCanvas: outputCanvas,
                videoPTSMasterInputDeviceID: $videoPTSMasterInputDeviceID,
                videoPTSMasterInputDeviceOptions: workspaceInputDeviceOptions.filter { $0.kind == .video },
                outputDestination: outputDestination,
                existingBroadcasts: existingBroadcasts,
                isLoadingBroadcasts: isLoadingBroadcasts,
                supportsYouTube: featureAvailability.supportsYouTube,
                refreshExistingBroadcasts: refreshExistingBroadcasts,
                manageYouTubeBroadcasts: manageYouTubeBroadcasts,
                chooseOutputDirectory: chooseOutputDirectory,
                applyOutputSettings: applyOutputSettings,
                captureFrame: captureFrame,
                openScreenshotsDirectory: openScreenshotsDirectory,
                startOutputSession: startOutputSession,
                pauseOutputSession: pauseOutputSession,
                stopOutputSession: stopOutputSession,
                resetSession: resetSession
            )
        case .inputDevice:
            InputDeviceDetailPane(
                inputDevices: $workspaceInputDevices,
                selectedInputDeviceID: selectedInputDeviceID,
                workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
                cameras: cameras,
                audioDevices: audioDevices,
                refreshPhysicalDevices: refreshCameras,
                deleteInputDevice: deleteWorkspaceInputDevice,
                previewPlacement: .hidden,
                supportsBackgroundRemoval: featureAvailability.supportsBackgroundRemoval,
                backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory
            )
            .disabled(windowState.mode != .edit || windowState.isOperationLocked)
        case .videoComponent:
            WorkspaceVideoComponentDetailPane(
                videoComponents: $videoComponents,
                selectedSidebarItem: $selectedSidebarItem,
                workspaceInputDevices: workspaceInputDeviceOptions,
                deleteVideoComponent: deleteWorkspaceVideoComponent,
                supportsBackgroundRemoval: featureAvailability.supportsBackgroundRemoval
            )
            .disabled(windowState.mode != .edit || windowState.isOperationLocked)
        case .vision:
            if case let .some(.vision(id)) = selectedSidebarItem {
                VisionDetailPane(
                    visions: $visions,
                    visionID: id,
                    inputDevices: workspaceInputDevices,
                    runtimePresenter: visionRuntimePresenter,
                    analyze: analyzeVision,
                    delete: deleteWorkspaceVision
                )
                // Vision can be configured while Output is running, but a
                // Workspace operation transition must not accept a new edit.
                // Existing Vision work keeps running independently.
                .disabled(
                    !featureAvailability.supportsVision || windowState.isOperationLocked
                )
            }
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
        if case let .some(.vision(id)) = selectedSidebarItem,
           visions.contains(where: { $0.id == id }) {
            return .vision
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
        return videoComponents.contains { $0.id == id }
    }

}

private enum WorkspaceDetailContentSelection {
    case streamSettings
    case inputDevice
    case videoComponent
    case vision
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
    @State private var visions: [WorkspaceVisionDefinition] = []
    private let visionRuntimePresenter = LDTXAppUIPreviewVisionRuntimePresenter()

    var body: some View {
        WorkspaceDetailPane(
            selectedSidebarItem: $selectedSidebarItem,
            compositeProgramDefinition: $compositeProgramDefinition,
            outputCanvas: LDTXAppUIPreviewFixtures.makeOutputCanvasModel(),
            workspaceCaptureSessionCoordinator: LDTXAppUIPreviewFixtures.makeWorkspaceCaptureSessionCoordinator(),
            workspaceInputDevices: $workspaceInputDevices,
            visions: $visions,
            videoComponents: .constant([]),
            videoPTSMasterInputDeviceID: .constant(nil),
            visionRuntimePresenter: visionRuntimePresenter,
            analyzeVision: { _ in },
            cameras: LDTXAppUIPreviewFixtures.cameras,
            audioDevices: LDTXAppUIPreviewFixtures.audioDevices,
            refreshCameras: {},
            deleteWorkspaceInputDevice: { _ in },
            workspaceInputDeviceOptions: workspaceInputDevices,
            outputDestination: LDTXAppUIPreviewFixtures.makeAppOutputSettings(),
            existingBroadcasts: LDTXAppUIPreviewFixtures.existingBroadcasts,
            isLoadingBroadcasts: false,
            refreshExistingBroadcasts: {},
            manageYouTubeBroadcasts: {},
        )
    }
}

private struct WorkspaceDetailPaneInputPreviewHost: View {
    @State private var selectedSidebarItem: WorkspaceSidebarItem? = .inputDevice("workspace-video-1")
    @State private var compositeProgramDefinition = LDTXAppUIPreviewFixtures.compositeProgramDefinition
    @State private var workspaceInputDevices = LDTXAppUIPreviewFixtures.workspaceInputDevices
    @State private var visions: [WorkspaceVisionDefinition] = []
    private let visionRuntimePresenter = LDTXAppUIPreviewVisionRuntimePresenter()

    var body: some View {
        WorkspaceDetailPane(
            selectedSidebarItem: $selectedSidebarItem,
            compositeProgramDefinition: $compositeProgramDefinition,
            outputCanvas: LDTXAppUIPreviewFixtures.makeOutputCanvasModel(),
            workspaceCaptureSessionCoordinator: LDTXAppUIPreviewFixtures.makeWorkspaceCaptureSessionCoordinator(),
            workspaceInputDevices: $workspaceInputDevices,
            visions: $visions,
            videoComponents: .constant([]),
            videoPTSMasterInputDeviceID: .constant(nil),
            visionRuntimePresenter: visionRuntimePresenter,
            analyzeVision: { _ in },
            cameras: LDTXAppUIPreviewFixtures.cameras,
            audioDevices: LDTXAppUIPreviewFixtures.audioDevices,
            refreshCameras: {},
            deleteWorkspaceInputDevice: { _ in },
            workspaceInputDeviceOptions: workspaceInputDevices,
            outputDestination: LDTXAppUIPreviewFixtures.makeAppOutputSettings(),
            existingBroadcasts: LDTXAppUIPreviewFixtures.existingBroadcasts,
            isLoadingBroadcasts: false,
            refreshExistingBroadcasts: {},
            manageYouTubeBroadcasts: {},
        )
    }
}
#endif
