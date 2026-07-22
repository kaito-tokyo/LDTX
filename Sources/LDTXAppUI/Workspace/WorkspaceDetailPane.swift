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
    @Binding var automations: [WorkspaceAutomationDefinition]
    var visionRuntimePresenter: any VisionRuntimePresenting
    var backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory? = nil
    var analyzeVision: (WorkspaceVisionDefinition) -> Void
    var runAutomation: (WorkspaceAutomationDefinition) -> Void
    var cameras: [InputPhysicalDeviceOption]
    var audioDevices: [InputPhysicalDeviceOption]
    var refreshCameras: () -> Void
    var deleteWorkspaceInputDevice: (String) -> Void
    var workspaceInputDeviceOptions: [WorkspaceInputDeviceRecord]
    var outputDestination: OutputDestinationModel
    var selectedProgramName: String? = nil
    var outputSessionControlState: OutputSessionControlState = .idle
    var isOutputOperationLocked: Bool = false
    var isOutputSessionStartEnabled: Bool = false
    var outputSessionStartLabel: String = "Start Output"
    var existingBroadcasts: [LiveBroadcastSummary]
    var isLoadingBroadcasts: Bool
    var isConnectingBroadcast: Bool
    var isStreamingToYouTube: Bool
    var isRecording: Bool
    var canSelectYouTubeBroadcast: Bool
    var featureAvailability: WorkspaceFeatureAvailability = .all
    var canEditInputDevices: Bool
    var canEditOutputSettings: Bool
    var localOutputStatus: String
    var refreshExistingBroadcasts: () -> Void
    var manageYouTubeBroadcasts: () -> Void
    var chooseLocalOutputDirectory: () -> Void
    var captureFrame: () -> Void = {}
    var openScreenshotsDirectory: () -> Void = {}
    var startOutputSession: () -> Void = {}
    var pauseOutputSession: () -> Void = {}
    var stopOutputSession: () -> Void = {}
    var resetSession: () -> Void = {}
    var showInputDevicePreviewEditor: (String) -> Void

    var body: some View {
        switch detailContentSelection {
        case .streamSettings:
            OutputOrchestrationDetailPane(
                selectedProgramName: selectedProgramName,
                outputSessionControlState: outputSessionControlState,
                isOutputOperationLocked: isOutputOperationLocked,
                isOutputSessionStartEnabled: isOutputSessionStartEnabled,
                outputSessionStartLabel: outputSessionStartLabel,
                outputCanvas: outputCanvas,
                outputDestination: outputDestination,
                existingBroadcasts: existingBroadcasts,
                isLoadingBroadcasts: isLoadingBroadcasts,
                isConnectingBroadcast: isConnectingBroadcast,
                isStreamingToYouTube: isStreamingToYouTube,
                isRecording: isRecording,
                canSelectYouTubeBroadcast: canSelectYouTubeBroadcast,
                supportsYouTube: featureAvailability.supportsYouTube,
                canEditOutputSettings: canEditOutputSettings,
                localOutputStatus: localOutputStatus,
                refreshExistingBroadcasts: refreshExistingBroadcasts,
                manageYouTubeBroadcasts: manageYouTubeBroadcasts,
                chooseLocalOutputDirectory: chooseLocalOutputDirectory,
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
                backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory,
                showPreviewEditor: showInputDevicePreviewEditor
            )
            .disabled(!canEditInputDevices)
        case .videoComponent:
            VideoComponentDetailPane(
                compositeProgramDefinition: $compositeProgramDefinition,
                selectedSidebarItem: $selectedSidebarItem,
                outputCanvas: outputCanvas,
                workspaceInputDevices: workspaceInputDeviceOptions
            )
        case .vision:
            if case let .some(.vision(id)) = selectedSidebarItem {
                VisionDetailPane(
                    visions: $visions,
                    visionID: id,
                    inputDevices: workspaceInputDevices,
                    automations: automations,
                    runtimePresenter: visionRuntimePresenter,
                    analyze: analyzeVision,
                    delete: deleteVision
                )
                .disabled(!featureAvailability.supportsVision)
            }
        case .automation:
            if case let .some(.automation(id)) = selectedSidebarItem {
                AutomationDetailPane(
                    automations: $automations,
                    automationID: id,
                    visions: visions,
                    inputDevices: workspaceInputDevices,
                    run: runAutomation,
                    delete: deleteAutomation
                )
                .disabled(!featureAvailability.supportsAutomation)
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
        if case let .some(.automation(id)) = selectedSidebarItem,
           automations.contains(where: { $0.id == id }) {
            return .automation
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

    private func deleteVision(id: String) {
        visions.removeAll { $0.id == id }
        selectedSidebarItem = .streamSettings
    }

    private func deleteAutomation(id: String) {
        automations.removeAll { $0.id == id }
        selectedSidebarItem = .streamSettings
    }
}

private enum WorkspaceDetailContentSelection {
    case streamSettings
    case inputDevice
    case videoComponent
    case vision
    case automation
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
    @State private var automations: [WorkspaceAutomationDefinition] = []
    private let visionRuntimePresenter = LDTXAppUIPreviewVisionRuntimePresenter()

    var body: some View {
        WorkspaceDetailPane(
            selectedSidebarItem: $selectedSidebarItem,
            compositeProgramDefinition: $compositeProgramDefinition,
            outputCanvas: LDTXAppUIPreviewFixtures.makeOutputCanvasModel(),
            workspaceCaptureSessionCoordinator: LDTXAppUIPreviewFixtures.makeWorkspaceCaptureSessionCoordinator(),
            workspaceInputDevices: $workspaceInputDevices,
            visions: $visions,
            automations: $automations,
            visionRuntimePresenter: visionRuntimePresenter,
            analyzeVision: { _ in },
            runAutomation: { _ in },
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
            canEditInputDevices: true,
            canEditOutputSettings: true,
            localOutputStatus: LDTXAppUIPreviewFixtures.localOutputStatus,
            refreshExistingBroadcasts: {},
            manageYouTubeBroadcasts: {},
            chooseLocalOutputDirectory: {},
            showInputDevicePreviewEditor: { _ in }
        )
    }
}

private struct WorkspaceDetailPaneInputPreviewHost: View {
    @State private var selectedSidebarItem: WorkspaceSidebarItem? = .inputDevice("workspace-video-1")
    @State private var compositeProgramDefinition = LDTXAppUIPreviewFixtures.compositeProgramDefinition
    @State private var workspaceInputDevices = LDTXAppUIPreviewFixtures.workspaceInputDevices
    @State private var visions: [WorkspaceVisionDefinition] = []
    @State private var automations: [WorkspaceAutomationDefinition] = []
    private let visionRuntimePresenter = LDTXAppUIPreviewVisionRuntimePresenter()

    var body: some View {
        WorkspaceDetailPane(
            selectedSidebarItem: $selectedSidebarItem,
            compositeProgramDefinition: $compositeProgramDefinition,
            outputCanvas: LDTXAppUIPreviewFixtures.makeOutputCanvasModel(),
            workspaceCaptureSessionCoordinator: LDTXAppUIPreviewFixtures.makeWorkspaceCaptureSessionCoordinator(),
            workspaceInputDevices: $workspaceInputDevices,
            visions: $visions,
            automations: $automations,
            visionRuntimePresenter: visionRuntimePresenter,
            analyzeVision: { _ in },
            runAutomation: { _ in },
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
            canEditInputDevices: true,
            canEditOutputSettings: true,
            localOutputStatus: LDTXAppUIPreviewFixtures.localOutputStatus,
            refreshExistingBroadcasts: {},
            manageYouTubeBroadcasts: {},
            chooseLocalOutputDirectory: {},
            showInputDevicePreviewEditor: { _ in }
        )
    }
}
#endif
