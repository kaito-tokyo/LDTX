// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
import LDTXYouTube
import SwiftUI

public struct WorkspaceView: View {
    @Binding private var selectedSidebarItem: WorkspaceSidebarItem?
    @Binding private var selectedProgramDefinitionName: String?
    @Binding private var workspaceInputDevices: [WorkspaceInputDeviceRecord]
    @Binding private var workspaceAudioChannels: [ProgramAudioChannel]
    @Binding private var compositeProgramDefinition: CompositeProgramDefinition
    @Binding private var programArguments: ProgramArguments
    @Binding private var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?
    @Binding private var programAddErrorMessage: String?
    @Binding private var isShowingProgramRenamePopover: Bool
    @Binding private var proposedProgramName: String
    @State private var presentedInputDevicePreviewEditorID: String?
    private var outputCanvas: OutputCanvasModel
    private var outputDestination: OutputDestinationModel

    private var workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator
    private var activeProgramRuntime: ActiveProgramRuntime
    private var activeProgramSnapshot: ProgramPreviewSnapshot
    private var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
    private var programRecords: [SavedProgramDefinitionRecord]
    private var activeProgramSelection: Binding<String?>
    private var inputCameraDeviceMappings: [String: String]
    private var audioPeakMeter: ProgramAudioPeakMeter
    private var cameras: [InputPhysicalDeviceOption]
    private var audioDevices: [InputPhysicalDeviceOption]
    private var existingBroadcasts: [YouTubeLiveBroadcast]
    private var isLoadingBroadcasts: Bool
    private var isConnectingBroadcast: Bool
    private var isStreamingToYouTube: Bool
    private var isRecording: Bool
    private var localOutputStatus: String
    private var canSelectYouTubeBroadcast: Bool
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
        selectedSidebarItem: Binding<WorkspaceSidebarItem?>,
        selectedProgramDefinitionName: Binding<String?>,
        workspaceInputDevices: Binding<[WorkspaceInputDeviceRecord]>,
        workspaceAudioChannels: Binding<[ProgramAudioChannel]>,
        compositeProgramDefinition: Binding<CompositeProgramDefinition>,
        programArguments: Binding<ProgramArguments>,
        saveProgramDefinitionCommand: Binding<ProgramDefinitionSaveCommand?>,
        programAddErrorMessage: Binding<String?>,
        isShowingProgramRenamePopover: Binding<Bool>,
        proposedProgramName: Binding<String>,
        outputCanvas: OutputCanvasModel,
        outputDestination: OutputDestinationModel,
        workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
        activeProgramRuntime: ActiveProgramRuntime,
        activeProgramSnapshot: ProgramPreviewSnapshot,
        selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?,
        programRecords: [SavedProgramDefinitionRecord],
        activeProgramSelection: Binding<String?>,
        inputCameraDeviceMappings: [String: String],
        audioPeakMeter: ProgramAudioPeakMeter,
        cameras: [InputPhysicalDeviceOption],
        audioDevices: [InputPhysicalDeviceOption],
        existingBroadcasts: [YouTubeLiveBroadcast],
        isLoadingBroadcasts: Bool,
        isConnectingBroadcast: Bool,
        isStreamingToYouTube: Bool,
        isRecording: Bool,
        localOutputStatus: String,
        canSelectYouTubeBroadcast: Bool,
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
        _workspaceAudioChannels = workspaceAudioChannels
        _compositeProgramDefinition = compositeProgramDefinition
        _programArguments = programArguments
        _saveProgramDefinitionCommand = saveProgramDefinitionCommand
        _programAddErrorMessage = programAddErrorMessage
        _isShowingProgramRenamePopover = isShowingProgramRenamePopover
        _proposedProgramName = proposedProgramName
        self.outputCanvas = outputCanvas
        self.outputDestination = outputDestination
        self.workspaceCaptureSessionCoordinator = workspaceCaptureSessionCoordinator
        self.activeProgramRuntime = activeProgramRuntime
        self.activeProgramSnapshot = activeProgramSnapshot
        self.selectedProgramDefinitionRecord = selectedProgramDefinitionRecord
        self.programRecords = programRecords
        self.activeProgramSelection = activeProgramSelection
        self.inputCameraDeviceMappings = inputCameraDeviceMappings
        self.audioPeakMeter = audioPeakMeter
        self.cameras = cameras
        self.audioDevices = audioDevices
        self.existingBroadcasts = existingBroadcasts
        self.isLoadingBroadcasts = isLoadingBroadcasts
        self.isConnectingBroadcast = isConnectingBroadcast
        self.isStreamingToYouTube = isStreamingToYouTube
        self.isRecording = isRecording
        self.localOutputStatus = localOutputStatus
        self.canSelectYouTubeBroadcast = canSelectYouTubeBroadcast
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
                selectedSidebarItem: $selectedSidebarItem,
                selectedProgramDefinitionName: selectedProgramDefinitionName,
                compositeProgramDefinition: $compositeProgramDefinition,
                outputCanvas: outputCanvas,
                outputDestination: outputDestination,
                workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
                activeProgramRuntime: activeProgramRuntime,
                activeProgramSnapshot: activeProgramSnapshot,
                selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
                programArguments: $programArguments,
                workspaceInputDevices: workspaceInputDevices,
                workspaceAudioChannels: workspaceAudioChannels,
                inputCameraDeviceMappings: inputCameraDeviceMappings,
                audioPeakMeter: audioPeakMeter,
                updateProgramAudioGains: updateProgramAudioGains
            )
        } detail: {
            workspaceDetailPane
        }
        .background {
            ProgramDefinitionEditorCoordinator(
                selectedProgramDefinitionName: $selectedProgramDefinitionName,
                compositeProgramDefinition: $compositeProgramDefinition,
                workspaceInputDevices: $workspaceInputDevices,
                outputCanvas: outputCanvas,
                selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
                reloadSavedProgramDefinitions: reloadSavedProgramDefinitions,
                refreshCameras: refreshCameras,
                saveProgramDefinitionRecord: saveProgramDefinitionRecord,
                programDefinitionDirtyChanged: programDefinitionDirtyChanged,
                saveProgramDefinitionCommand: $saveProgramDefinitionCommand
            )
            .frame(width: 0, height: 0)
        }
        .toolbar {
            workspaceToolbar
        }
        .alert("Program Could Not Be Added", isPresented: programAddErrorPresentedBinding) {
            Button("OK", role: .cancel) {
                programAddErrorMessage = nil
            }
        } message: {
            Text(programAddErrorMessage ?? "")
        }
        .sheet(isPresented: inputDevicePreviewEditorPresentedBinding) {
            InputDevicePreviewEditorModal(
                inputDevices: $workspaceInputDevices,
                selectedInputDeviceID: $presentedInputDevicePreviewEditorID,
                workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
                cameras: cameras,
                audioDevices: audioDevices,
                refreshPhysicalDevices: refreshCameras,
                deleteInputDevice: deleteWorkspaceInputDevice,
                close: {
                    presentedInputDevicePreviewEditorID = nil
                }
            )
            .frame(width: 560, height: 720)
        }
        .onAppear {
            outputCanvas.sync(from: selectedProgramDefinitionRecord)
        }
        .onChange(of: selectedProgramDefinitionRecord) { _, _ in
            outputCanvas.sync(from: selectedProgramDefinitionRecord)
        }
        .onChange(of: compositeProgramDefinition.steps.map(\.id)) { _, stepIDs in
            if case let .some(.videoComponent(id)) = selectedSidebarItem,
               !stepIDs.contains(id) {
                selectedSidebarItem = .streamSettings
            }
        }
        .onChange(of: workspaceInputDevices.map(\.id)) { _, inputDeviceIDs in
            if case let .some(.inputDevice(id)) = selectedSidebarItem,
               !inputDeviceIDs.contains(id) {
                selectedSidebarItem = .streamSettings
            }
            if let presentedInputDevicePreviewEditorID,
               !inputDeviceIDs.contains(presentedInputDevicePreviewEditorID) {
                self.presentedInputDevicePreviewEditorID = nil
            }
        }
        .frame(minWidth: 920, minHeight: 620)
    }

    private var workspaceDetailPane: some View {
        WorkspaceDetailPane(
            selectedSidebarItem: $selectedSidebarItem,
            compositeProgramDefinition: $compositeProgramDefinition,
            outputCanvas: outputCanvas,
            workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
            workspaceInputDevices: $workspaceInputDevices,
            cameras: cameras,
            audioDevices: audioDevices,
            refreshCameras: refreshCameras,
            deleteWorkspaceInputDevice: deleteWorkspaceInputDevice,
            workspaceInputDeviceOptions: workspaceInputDevices,
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
            chooseLocalOutputDirectory: chooseLocalOutputDirectory,
            showInputDevicePreviewEditor: { inputDeviceID in
                presentedInputDevicePreviewEditorID = inputDeviceID
            }
        )
    }

    private var inputDevicePreviewEditorPresentedBinding: Binding<Bool> {
        Binding(
            get: { presentedInputDevicePreviewEditorID != nil },
            set: { isPresented in
                if !isPresented {
                    presentedInputDevicePreviewEditorID = nil
                }
            }
        )
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        outputSessionToolbar
        programManagementToolbar
        workspaceFileToolbar
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
}

private struct InputDevicePreviewEditorModal: View {
    @Binding var inputDevices: [WorkspaceInputDeviceRecord]
    @Binding var selectedInputDeviceID: String?
    var workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator
    var cameras: [InputPhysicalDeviceOption]
    var audioDevices: [InputPhysicalDeviceOption]
    var refreshPhysicalDevices: () -> Void
    var deleteInputDevice: (String) -> Void
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedInputDeviceName)
                        .font(.headline)
                    Text("Input Device Preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: close) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close Preview Editor")
                .accessibilityIdentifier("closeInputDevicePreviewEditorButton")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            InputDeviceDetailPane(
                inputDevices: $inputDevices,
                selectedInputDeviceID: $selectedInputDeviceID,
                workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
                cameras: cameras,
                audioDevices: audioDevices,
                refreshPhysicalDevices: refreshPhysicalDevices,
                deleteInputDevice: deleteInputDevice,
                previewPlacement: .beforeSettings,
                showsDeleteSection: false
            )
        }
        .accessibilityIdentifier("inputDevicePreviewEditorModal")
    }

    private var selectedInputDeviceName: String {
        guard let selectedInputDeviceID,
              let inputDevice = inputDevices.first(where: { $0.id == selectedInputDeviceID }) else {
            return "Input Device"
        }
        return inputDevice.name
    }
}

#if DEBUG
#Preview("Workspace View") {
    WorkspaceViewPreviewHost()
        .frame(width: 1280, height: 820)
}

private struct WorkspaceViewPreviewHost: View {
    @State private var selectedSidebarItem = LDTXAppUIPreviewFixtures.selectedSidebarItem
    @State private var selectedProgramDefinitionName =
        LDTXAppUIPreviewFixtures.selectedProgramDefinitionName
    @State private var workspaceInputDevices = LDTXAppUIPreviewFixtures.workspaceInputDevices
    @State private var workspaceAudioChannels = LDTXAppUIPreviewFixtures.workspaceAudioChannels
    @State private var compositeProgramDefinition = LDTXAppUIPreviewFixtures.compositeProgramDefinition
    @State private var programArguments = LDTXAppUIPreviewFixtures.programArguments
    @State private var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?
    @State private var programAddErrorMessage: String?
    @State private var isShowingProgramRenamePopover = false
    @State private var proposedProgramName = "Demo Program Copy"
    @State private var outputCanvas = LDTXAppUIPreviewFixtures.makeOutputCanvasModel()
    @State private var outputDestination = LDTXAppUIPreviewFixtures.makeOutputDestinationModel()
    private let workspaceCaptureSessionCoordinator = LDTXAppUIPreviewFixtures.makeWorkspaceCaptureSessionCoordinator()

    private var previewRuntime: ActiveProgramRuntime {
        LDTXAppUIPreviewFixtures.makeActiveProgramRuntime(
            coordinator: workspaceCaptureSessionCoordinator
        )
    }

    private var previewSnapshot: ProgramPreviewSnapshot {
        LDTXAppUIPreviewFixtures.makeActiveProgramSnapshot(
            outputCanvas: outputCanvas,
            compositeProgramDefinition: compositeProgramDefinition,
            workspaceInputDevices: workspaceInputDevices,
            workspaceAudioChannels: workspaceAudioChannels,
            inputCameraDeviceMappings: LDTXAppUIPreviewFixtures.inputCameraDeviceMappings
        )
    }

    var body: some View {
        WorkspaceView(
            selectedSidebarItem: $selectedSidebarItem,
            selectedProgramDefinitionName: $selectedProgramDefinitionName,
            workspaceInputDevices: $workspaceInputDevices,
            workspaceAudioChannels: $workspaceAudioChannels,
            compositeProgramDefinition: $compositeProgramDefinition,
            programArguments: $programArguments,
            saveProgramDefinitionCommand: $saveProgramDefinitionCommand,
            programAddErrorMessage: $programAddErrorMessage,
            isShowingProgramRenamePopover: $isShowingProgramRenamePopover,
            proposedProgramName: $proposedProgramName,
            outputCanvas: outputCanvas,
            outputDestination: outputDestination,
            workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
            activeProgramRuntime: previewRuntime,
            activeProgramSnapshot: previewSnapshot,
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
            existingBroadcasts: LDTXAppUIPreviewFixtures.existingBroadcasts,
            isLoadingBroadcasts: false,
            isConnectingBroadcast: false,
            isStreamingToYouTube: false,
            isRecording: false,
            localOutputStatus: LDTXAppUIPreviewFixtures.localOutputStatus,
            canSelectYouTubeBroadcast: true,
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
#endif
