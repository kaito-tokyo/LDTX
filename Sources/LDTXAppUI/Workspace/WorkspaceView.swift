// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
import LDTXYouTube
import SwiftUI

public struct WorkspaceView: View {
    @Binding private var selectedSidebarItem: WorkspaceSidebarItem
    @Binding private var selectedProgramDefinitionName: String?
    @Binding private var workspaceInputDevices: [WorkspaceInputDeviceRecord]
    @Binding private var compositeProgramDefinition: CompositeProgramDefinition
    @Binding private var programArguments: ProgramArguments
    @Binding private var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?
    @Binding private var programAddErrorMessage: String?
    @Binding private var isShowingProgramRenamePopover: Bool
    @Binding private var proposedProgramName: String
    private var outputCanvas: OutputCanvasModel
    private var outputDestination: OutputDestinationModel

    private var workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator
    private var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
    private var programRecords: [SavedProgramDefinitionRecord]
    private var activeProgramSelection: Binding<String?>
    private var inputCameraDeviceMappings: [String: String]
    private var audioPeakMeter: ProgramAudioPeakMeter
    private var cameras: [InputPhysicalDeviceOption]
    private var audioDevices: [InputPhysicalDeviceOption]
    private var oauthClientStatus: String
    private var authorizationStatus: String
    private var streamStatus: String
    private var captureStatus: String
    private var existingBroadcasts: [YouTubeLiveBroadcast]
    private var isLoadingBroadcasts: Bool
    private var isConnectingBroadcast: Bool
    private var isStreamingToYouTube: Bool
    private var isRecording: Bool
    private var localOutputStatus: String
    private var isOutputSessionRunning: Bool
    private var isGlobalOutputSessionStartEnabled: Bool
    private var globalOutputSessionStartAccessibilityLabel: String
    private var globalOutputSessionStartHelp: String
    private var globalOutputSessionStopHelp: String
    private var isWorkspaceSaveToolbarEnabled: Bool
    private var updateProgramAudioGains: (ProgramArguments) -> Void
    private var reloadSavedProgramDefinitions: () -> Void
    private var refreshCameras: () -> Void
    private var deleteWorkspaceInputDevice: (String) -> Void
    private var saveProgramDefinitionRecord: (SavedProgramDefinitionRecord) -> Bool
    private var programDefinitionDirtyChanged: (Bool) -> Void
    private var stopOutputSession: () -> Void
    private var startOutputSession: () -> Void
    private var addProgramDefinition: () -> Void
    private var showProgramRenamePopover: () -> Void
    private var renameSelectedProgramDefinitionFromPopover: () -> Void
    private var saveWorkspace: () -> Void
    private var refreshExistingBroadcasts: () -> Void
    private var manageYouTubeBroadcasts: () -> Void
    private var chooseLocalOutputDirectory: () -> Void

    public init(
        selectedSidebarItem: Binding<WorkspaceSidebarItem>,
        selectedProgramDefinitionName: Binding<String?>,
        workspaceInputDevices: Binding<[WorkspaceInputDeviceRecord]>,
        compositeProgramDefinition: Binding<CompositeProgramDefinition>,
        programArguments: Binding<ProgramArguments>,
        saveProgramDefinitionCommand: Binding<ProgramDefinitionSaveCommand?>,
        programAddErrorMessage: Binding<String?>,
        isShowingProgramRenamePopover: Binding<Bool>,
        proposedProgramName: Binding<String>,
        outputCanvas: OutputCanvasModel,
        outputDestination: OutputDestinationModel,
        workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
        selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?,
        programRecords: [SavedProgramDefinitionRecord],
        activeProgramSelection: Binding<String?>,
        inputCameraDeviceMappings: [String: String],
        audioPeakMeter: ProgramAudioPeakMeter,
        cameras: [InputPhysicalDeviceOption],
        audioDevices: [InputPhysicalDeviceOption],
        oauthClientStatus: String,
        authorizationStatus: String,
        streamStatus: String,
        captureStatus: String,
        existingBroadcasts: [YouTubeLiveBroadcast],
        isLoadingBroadcasts: Bool,
        isConnectingBroadcast: Bool,
        isStreamingToYouTube: Bool,
        isRecording: Bool,
        localOutputStatus: String,
        isOutputSessionRunning: Bool,
        isGlobalOutputSessionStartEnabled: Bool,
        globalOutputSessionStartAccessibilityLabel: String,
        globalOutputSessionStartHelp: String,
        globalOutputSessionStopHelp: String,
        isWorkspaceSaveToolbarEnabled: Bool,
        updateProgramAudioGains: @escaping (ProgramArguments) -> Void,
        reloadSavedProgramDefinitions: @escaping () -> Void,
        refreshCameras: @escaping () -> Void,
        deleteWorkspaceInputDevice: @escaping (String) -> Void,
        saveProgramDefinitionRecord: @escaping (SavedProgramDefinitionRecord) -> Bool,
        programDefinitionDirtyChanged: @escaping (Bool) -> Void,
        stopOutputSession: @escaping () -> Void,
        startOutputSession: @escaping () -> Void,
        addProgramDefinition: @escaping () -> Void,
        showProgramRenamePopover: @escaping () -> Void,
        renameSelectedProgramDefinitionFromPopover: @escaping () -> Void,
        saveWorkspace: @escaping () -> Void,
        refreshExistingBroadcasts: @escaping () -> Void,
        manageYouTubeBroadcasts: @escaping () -> Void,
        chooseLocalOutputDirectory: @escaping () -> Void
    ) {
        _selectedSidebarItem = selectedSidebarItem
        _selectedProgramDefinitionName = selectedProgramDefinitionName
        _workspaceInputDevices = workspaceInputDevices
        _compositeProgramDefinition = compositeProgramDefinition
        _programArguments = programArguments
        _saveProgramDefinitionCommand = saveProgramDefinitionCommand
        _programAddErrorMessage = programAddErrorMessage
        _isShowingProgramRenamePopover = isShowingProgramRenamePopover
        _proposedProgramName = proposedProgramName
        self.outputCanvas = outputCanvas
        self.outputDestination = outputDestination
        self.workspaceCaptureSessionCoordinator = workspaceCaptureSessionCoordinator
        self.selectedProgramDefinitionRecord = selectedProgramDefinitionRecord
        self.programRecords = programRecords
        self.activeProgramSelection = activeProgramSelection
        self.inputCameraDeviceMappings = inputCameraDeviceMappings
        self.audioPeakMeter = audioPeakMeter
        self.cameras = cameras
        self.audioDevices = audioDevices
        self.oauthClientStatus = oauthClientStatus
        self.authorizationStatus = authorizationStatus
        self.streamStatus = streamStatus
        self.captureStatus = captureStatus
        self.existingBroadcasts = existingBroadcasts
        self.isLoadingBroadcasts = isLoadingBroadcasts
        self.isConnectingBroadcast = isConnectingBroadcast
        self.isStreamingToYouTube = isStreamingToYouTube
        self.isRecording = isRecording
        self.localOutputStatus = localOutputStatus
        self.isOutputSessionRunning = isOutputSessionRunning
        self.isGlobalOutputSessionStartEnabled = isGlobalOutputSessionStartEnabled
        self.globalOutputSessionStartAccessibilityLabel = globalOutputSessionStartAccessibilityLabel
        self.globalOutputSessionStartHelp = globalOutputSessionStartHelp
        self.globalOutputSessionStopHelp = globalOutputSessionStopHelp
        self.isWorkspaceSaveToolbarEnabled = isWorkspaceSaveToolbarEnabled
        self.updateProgramAudioGains = updateProgramAudioGains
        self.reloadSavedProgramDefinitions = reloadSavedProgramDefinitions
        self.refreshCameras = refreshCameras
        self.deleteWorkspaceInputDevice = deleteWorkspaceInputDevice
        self.saveProgramDefinitionRecord = saveProgramDefinitionRecord
        self.programDefinitionDirtyChanged = programDefinitionDirtyChanged
        self.stopOutputSession = stopOutputSession
        self.startOutputSession = startOutputSession
        self.addProgramDefinition = addProgramDefinition
        self.showProgramRenamePopover = showProgramRenamePopover
        self.renameSelectedProgramDefinitionFromPopover = renameSelectedProgramDefinitionFromPopover
        self.saveWorkspace = saveWorkspace
        self.refreshExistingBroadcasts = refreshExistingBroadcasts
        self.manageYouTubeBroadcasts = manageYouTubeBroadcasts
        self.chooseLocalOutputDirectory = chooseLocalOutputDirectory
    }

    public var body: some View {
        NavigationSplitView {
            WorkspaceSidebarPane(
                selectedSidebarItem: $selectedSidebarItem,
                workspaceInputDevices: $workspaceInputDevices
            )
        } content: {
            WorkspaceContentPane(
                compositeProgramDefinition: $compositeProgramDefinition,
                outputCanvas: outputCanvas,
                outputDestination: outputDestination,
                workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
                selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
                programArguments: $programArguments,
                workspaceInputDevices: workspaceInputDevices,
                inputCameraDeviceMappings: inputCameraDeviceMappings,
                audioPeakMeter: audioPeakMeter,
                updateProgramAudioGains: updateProgramAudioGains
            )
        } detail: {
            WorkspaceDetailPane(
                selectedSidebarItem: $selectedSidebarItem,
                selectedProgramDefinitionName: $selectedProgramDefinitionName,
                compositeProgramDefinition: $compositeProgramDefinition,
                outputCanvas: outputCanvas,
                workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
                workspaceInputDevices: $workspaceInputDevices,
                cameras: cameras,
                audioDevices: audioDevices,
                selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
                reloadSavedProgramDefinitions: reloadSavedProgramDefinitions,
                refreshCameras: refreshCameras,
                deleteWorkspaceInputDevice: deleteWorkspaceInputDevice,
                saveProgramDefinitionRecord: saveProgramDefinitionRecord,
                programDefinitionDirtyChanged: programDefinitionDirtyChanged,
                saveProgramDefinitionCommand: $saveProgramDefinitionCommand
            )
        }
        .toolbar {
            outputSessionToolbar
            programManagementToolbar
            workspaceFileToolbar
        }
        .sheet(isPresented: outputSettingsPresentedBinding) {
            OutputSettingsSheet(
                oauthClientStatus: oauthClientStatus,
                authorizationStatus: authorizationStatus,
                streamStatus: streamStatus,
                captureStatus: captureStatus,
                outputDestination: outputDestination,
                existingBroadcasts: existingBroadcasts,
                isLoadingBroadcasts: isLoadingBroadcasts,
                isConnectingBroadcast: isConnectingBroadcast,
                isStreamingToYouTube: isStreamingToYouTube,
                isRecording: isRecording,
                localOutputStatus: localOutputStatus,
                refreshExistingBroadcasts: refreshExistingBroadcasts,
                manageYouTubeBroadcasts: manageYouTubeBroadcasts,
                chooseLocalOutputDirectory: chooseLocalOutputDirectory
            )
        }
        .alert("Program Could Not Be Added", isPresented: programAddErrorPresentedBinding) {
            Button("OK", role: .cancel) {
                programAddErrorMessage = nil
            }
        } message: {
            Text(programAddErrorMessage ?? "")
        }
        .onAppear {
            outputCanvas.sync(from: selectedProgramDefinitionRecord)
        }
        .onChange(of: selectedProgramDefinitionRecord) { _, _ in
            outputCanvas.sync(from: selectedProgramDefinitionRecord)
        }
        .frame(minWidth: 920, minHeight: 620)
    }

    @ToolbarContentBuilder
    private var outputSessionToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                stopOutputSession()
            } label: {
                Image(systemName: "stop.fill")
            }
            .disabled(!isOutputSessionRunning)
            .help(globalOutputSessionStopHelp)
            .accessibilityLabel("Stop Output")
            .accessibilityIdentifier("toolbarStopOutputSessionButton")

            Button {
                startOutputSession()
            } label: {
                Image(systemName: "play.fill")
            }
            .disabled(!isGlobalOutputSessionStartEnabled)
            .help(globalOutputSessionStartHelp)
            .accessibilityLabel(globalOutputSessionStartAccessibilityLabel)
            .accessibilityIdentifier("toolbarStartOutputSessionButton")

            if isLoadingBroadcasts || isConnectingBroadcast {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    @ToolbarContentBuilder
    private var programManagementToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 8) {
                Picker("Program", selection: activeProgramSelection) {
                    ForEach(programRecords, id: \.name) { record in
                        Text(record.name).tag(Optional(record.name))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 180, maxWidth: 260)
                .accessibilityIdentifier("activeProgramPicker")

                Button {
                    addProgramDefinition()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add Program")
                .accessibilityLabel("Add Program")
                .accessibilityIdentifier("toolbarAddProgramButton")

                Menu {
                    Button {
                        showProgramRenamePopover()
                    } label: {
                        Label("Rename...", systemImage: "pencil")
                    }
                    .disabled(selectedProgramDefinitionName == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .disabled(selectedProgramDefinitionName == nil)
                .help("Program Actions")
                .accessibilityLabel("Program Actions")
                .accessibilityIdentifier("toolbarProgramActionsMenu")
                .popover(isPresented: $isShowingProgramRenamePopover, arrowEdge: .bottom) {
                    ProgramRenamePopover(
                        name: $proposedProgramName,
                        currentName: selectedProgramDefinitionName ?? "",
                        renameProgram: renameSelectedProgramDefinitionFromPopover
                    )
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var workspaceFileToolbar: some ToolbarContent {
        ToolbarSpacer(.flexible)

        ToolbarItem(placement: .primaryAction) {
            Button {
                saveWorkspace()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(!isWorkspaceSaveToolbarEnabled)
            .help("Save Workspace")
            .accessibilityLabel("Save Workspace")
            .accessibilityIdentifier("toolbarSaveWorkspaceButton")
        }
    }

    private var programAddErrorPresentedBinding: Binding<Bool> {
        Binding(
            get: { programAddErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    programAddErrorMessage = nil
                }
            }
        )
    }

    private var outputSettingsPresentedBinding: Binding<Bool> {
        Binding(
            get: { outputDestination.isShowingOutputSettings },
            set: { outputDestination.isShowingOutputSettings = $0 }
        )
    }
}

private struct OutputSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var oauthClientStatus: String
    var authorizationStatus: String
    var streamStatus: String
    var captureStatus: String
    var outputDestination: OutputDestinationModel
    var existingBroadcasts: [YouTubeLiveBroadcast]
    var isLoadingBroadcasts: Bool
    var isConnectingBroadcast: Bool
    var isStreamingToYouTube: Bool
    var isRecording: Bool
    var localOutputStatus: String
    var refreshExistingBroadcasts: () -> Void
    var manageYouTubeBroadcasts: () -> Void
    var chooseLocalOutputDirectory: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ContentSettingsForm(
                    oauthClientStatus: oauthClientStatus,
                    authorizationStatus: authorizationStatus,
                    streamStatus: streamStatus,
                    captureStatus: captureStatus,
                    outputDestination: outputDestination,
                    existingBroadcasts: existingBroadcasts,
                    isLoadingBroadcasts: isLoadingBroadcasts,
                    isConnectingBroadcast: isConnectingBroadcast,
                    isStreamingToYouTube: isStreamingToYouTube,
                    isRecording: isRecording,
                    localOutputStatus: localOutputStatus,
                    refreshExistingBroadcasts: refreshExistingBroadcasts,
                    manageYouTubeBroadcasts: manageYouTubeBroadcasts,
                    chooseLocalOutputDirectory: chooseLocalOutputDirectory,
                    placement: .modal
                )
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
    }
}

#if DEBUG
#Preview("Workspace View") {
    WorkspaceViewPreviewHost()
        .frame(width: 1280, height: 820)
}

#Preview("Output Settings Sheet") {
    OutputSettingsSheetPreviewHost()
        .frame(width: 560, height: 680)
}

private struct WorkspaceViewPreviewHost: View {
    @State private var selectedSidebarItem = LDTXAppUIPreviewFixtures.selectedSidebarItem
    @State private var selectedProgramDefinitionName =
        LDTXAppUIPreviewFixtures.selectedProgramDefinitionName
    @State private var workspaceInputDevices = LDTXAppUIPreviewFixtures.workspaceInputDevices
    @State private var compositeProgramDefinition = LDTXAppUIPreviewFixtures.compositeProgramDefinition
    @State private var programArguments = LDTXAppUIPreviewFixtures.programArguments
    @State private var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?
    @State private var programAddErrorMessage: String?
    @State private var isShowingProgramRenamePopover = false
    @State private var proposedProgramName = "Demo Program Copy"
    @State private var outputCanvas = LDTXAppUIPreviewFixtures.makeOutputCanvasModel()
    @State private var outputDestination = LDTXAppUIPreviewFixtures.makeOutputDestinationModel()

    var body: some View {
        WorkspaceView(
            selectedSidebarItem: $selectedSidebarItem,
            selectedProgramDefinitionName: $selectedProgramDefinitionName,
            workspaceInputDevices: $workspaceInputDevices,
            compositeProgramDefinition: $compositeProgramDefinition,
            programArguments: $programArguments,
            saveProgramDefinitionCommand: $saveProgramDefinitionCommand,
            programAddErrorMessage: $programAddErrorMessage,
            isShowingProgramRenamePopover: $isShowingProgramRenamePopover,
            proposedProgramName: $proposedProgramName,
            outputCanvas: outputCanvas,
            outputDestination: outputDestination,
            workspaceCaptureSessionCoordinator: LDTXAppUIPreviewFixtures.makeWorkspaceCaptureSessionCoordinator(),
            selectedProgramDefinitionRecord: LDTXAppUIPreviewFixtures.selectedProgramDefinitionRecord,
            programRecords: LDTXAppUIPreviewFixtures.programRecords,
            activeProgramSelection: Binding(
                get: { selectedProgramDefinitionName },
                set: { selectedProgramDefinitionName = $0 }
            ),
            inputCameraDeviceMappings: LDTXAppUIPreviewFixtures.inputCameraDeviceMappings,
            audioPeakMeter: LDTXAppUIPreviewFixtures.makeAudioPeakMeter(),
            cameras: LDTXAppUIPreviewFixtures.cameras,
            audioDevices: LDTXAppUIPreviewFixtures.audioDevices,
            oauthClientStatus: LDTXAppUIPreviewFixtures.oauthClientStatus,
            authorizationStatus: LDTXAppUIPreviewFixtures.authorizationStatus,
            streamStatus: LDTXAppUIPreviewFixtures.streamStatus,
            captureStatus: LDTXAppUIPreviewFixtures.captureStatus,
            existingBroadcasts: LDTXAppUIPreviewFixtures.existingBroadcasts,
            isLoadingBroadcasts: false,
            isConnectingBroadcast: false,
            isStreamingToYouTube: false,
            isRecording: false,
            localOutputStatus: LDTXAppUIPreviewFixtures.localOutputStatus,
            isOutputSessionRunning: false,
            isGlobalOutputSessionStartEnabled: true,
            globalOutputSessionStartAccessibilityLabel: "Start Output",
            globalOutputSessionStartHelp: "Start streaming or recording",
            globalOutputSessionStopHelp: "Stop the current output session",
            isWorkspaceSaveToolbarEnabled: true,
            updateProgramAudioGains: { programArguments = $0 },
            reloadSavedProgramDefinitions: {},
            refreshCameras: {},
            deleteWorkspaceInputDevice: { _ in },
            saveProgramDefinitionRecord: { _ in true },
            programDefinitionDirtyChanged: { _ in },
            stopOutputSession: {},
            startOutputSession: {},
            addProgramDefinition: {},
            showProgramRenamePopover: {
                proposedProgramName = selectedProgramDefinitionName ?? ""
                isShowingProgramRenamePopover = true
            },
            renameSelectedProgramDefinitionFromPopover: {
                selectedProgramDefinitionName = proposedProgramName
                isShowingProgramRenamePopover = false
            },
            saveWorkspace: {},
            refreshExistingBroadcasts: {},
            manageYouTubeBroadcasts: {},
            chooseLocalOutputDirectory: {}
        )
    }
}

private struct OutputSettingsSheetPreviewHost: View {
    @State private var outputDestination = LDTXAppUIPreviewFixtures.makeOutputDestinationModel()

    var body: some View {
        OutputSettingsSheet(
            oauthClientStatus: LDTXAppUIPreviewFixtures.oauthClientStatus,
            authorizationStatus: LDTXAppUIPreviewFixtures.authorizationStatus,
            streamStatus: LDTXAppUIPreviewFixtures.streamStatus,
            captureStatus: LDTXAppUIPreviewFixtures.captureStatus,
            outputDestination: outputDestination,
            existingBroadcasts: LDTXAppUIPreviewFixtures.existingBroadcasts,
            isLoadingBroadcasts: false,
            isConnectingBroadcast: false,
            isStreamingToYouTube: false,
            isRecording: false,
            localOutputStatus: LDTXAppUIPreviewFixtures.localOutputStatus,
            refreshExistingBroadcasts: {},
            manageYouTubeBroadcasts: {},
            chooseLocalOutputDirectory: {}
        )
    }
}
#endif
