// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXInternalProtocols
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
import SwiftUI

public enum OutputSessionControlState: Sendable {
  case idle
  case starting
  case running
  case pausing
  case readyToRestart
  case stopping
}

public struct WorkspaceView: View {
  @Binding private var selectedSidebarItem: WorkspaceSidebarItem?
  @Binding private var selectedProgramDefinitionName: String?
  @Binding private var workspaceInputDevices: [WorkspaceInputDeviceRecord]
  @Binding private var workspaceAudioChannels: [ProgramAudioChannel]
  @Binding private var visions: [WorkspaceVisionDefinition]
  @Binding private var automations: [WorkspaceAutomationDefinition]
  @Binding private var compositeProgramDefinition: CompositeProgramDefinition
  @Binding private var programPreferences: ProgramPreferences
  @Binding private var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?
  @Binding private var programAddErrorMessage: String?
  @Binding private var presentedErrorDialog: ErrorDialogKind?
  @Binding private var isShowingProgramRenameDialog: Bool
  @Binding private var proposedProgramName: String
  @Binding private var captureFrameFeedback: OutputFrameCaptureFeedback?
  @State private var presentedInputDevicePreviewEditorID: String?
  @State private var isShowingAddProgramDialog = false
  @State private var proposedNewProgramName = ""
  private var outputCanvas: OutputCanvasModel
  private var outputDestination: OutputDestinationModel
  private var visionRuntimePresenter: any VisionRuntimePresenting
  private var backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory?
  private var featureAvailability: WorkspaceFeatureAvailability

  private var workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  private var activeProgramRuntime: ActiveProgramRuntime
  private var activeProgramSnapshot: ProgramPreviewSnapshot
  private var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
  private var programRecords: [SavedProgramDefinitionRecord]
  private var activeProgramSelection: Binding<String?>
  private var inputCameraDeviceMappings: [String: String]
  private var audioPeakMeter: ProgramAudioPeakMeter
  private var inputAudioPassthroughChannelKeys: Binding<Set<String>>
  private var cameras: [InputPhysicalDeviceOption]
  private var audioDevices: [InputPhysicalDeviceOption]
  private var existingBroadcasts: [LiveBroadcastSummary]
  private var isLoadingBroadcasts: Bool
  private var isConnectingBroadcast: Bool
  private var isStreamingToYouTube: Bool
  private var isRecording: Bool
  private var localOutputStatus: String
  private var canSelectYouTubeBroadcast: Bool
  private var isOutputSessionRunning: Bool
  private var outputSessionControlState: OutputSessionControlState
  private var isOutputOperationLocked: Bool
  private var canEditInputDevices: Bool
  private var canEditOutputSettings: Bool
  private var isGlobalOutputSessionStartEnabled: Bool
  private var globalOutputSessionStartAccessibilityLabel: String
  private var globalOutputSessionStartHelp: String
  private var globalOutputSessionStopHelp: String
  private var isWorkspaceSaveToolbarEnabled: Bool
  private var updateProgramAudioGains: (ProgramPreferences) -> Void
  private var reloadSavedProgramDefinitions: () -> Void
  private var refreshCameras: () -> Void
  private var deleteWorkspaceInputDevice: (String) -> Void
  private var saveProgramDefinitionRecord: (SavedProgramDefinitionRecord) -> Bool
  private var programDefinitionDirtyChanged: (Bool) -> Void
  private var stopOutputSession: () -> Void
  private var startOutputSession: () -> Void
  private var pauseOutputSession: () -> Void
  private var resetSession: () -> Void
  private var addProgramDefinition: (String) -> Void
  private var showProgramRenameDialog: () -> Void
  private var renameSelectedProgramDefinitionFromDialog: () -> Void
  private var deleteSelectedProgramDefinition: () -> Void
  private var saveWorkspace: () -> Void
  private var refreshExistingBroadcasts: () -> Void
  private var manageYouTubeBroadcasts: () -> Void
  private var chooseLocalOutputDirectory: () -> Void
  private var analyzeVision: (WorkspaceVisionDefinition) -> Void
  private var runAutomation: (WorkspaceAutomationDefinition) -> Void
  private var captureFrame: () -> Void
  private var openScreenshotsDirectory: () -> Void

  public init(
    selectedSidebarItem: Binding<WorkspaceSidebarItem?>,
    selectedProgramDefinitionName: Binding<String?>,
    workspaceInputDevices: Binding<[WorkspaceInputDeviceRecord]>,
    workspaceAudioChannels: Binding<[ProgramAudioChannel]>,
    visions: Binding<[WorkspaceVisionDefinition]>,
    automations: Binding<[WorkspaceAutomationDefinition]>,
    compositeProgramDefinition: Binding<CompositeProgramDefinition>,
    programPreferences: Binding<ProgramPreferences>,
    saveProgramDefinitionCommand: Binding<ProgramDefinitionSaveCommand?>,
    programAddErrorMessage: Binding<String?>,
    presentedErrorDialog: Binding<ErrorDialogKind?>,
    isShowingProgramRenameDialog: Binding<Bool>,
    proposedProgramName: Binding<String>,
    captureFrameFeedback: Binding<OutputFrameCaptureFeedback?>,
    outputCanvas: OutputCanvasModel,
    outputDestination: OutputDestinationModel,
    visionRuntimePresenter: any VisionRuntimePresenting,
    backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory? = nil,
    workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    activeProgramRuntime: ActiveProgramRuntime,
    activeProgramSnapshot: ProgramPreviewSnapshot,
    selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?,
    programRecords: [SavedProgramDefinitionRecord],
    activeProgramSelection: Binding<String?>,
    inputCameraDeviceMappings: [String: String],
    audioPeakMeter: ProgramAudioPeakMeter,
    inputAudioPassthroughChannelKeys: Binding<Set<String>>,
    cameras: [InputPhysicalDeviceOption],
    audioDevices: [InputPhysicalDeviceOption],
    existingBroadcasts: [LiveBroadcastSummary],
    isLoadingBroadcasts: Bool,
    isConnectingBroadcast: Bool,
    isStreamingToYouTube: Bool,
    isRecording: Bool,
    localOutputStatus: String,
    canSelectYouTubeBroadcast: Bool,
    isOutputSessionRunning: Bool,
    outputSessionControlState: OutputSessionControlState,
    isOutputOperationLocked: Bool,
    canEditInputDevices: Bool,
    canEditOutputSettings: Bool,
    isGlobalOutputSessionStartEnabled: Bool,
    globalOutputSessionStartAccessibilityLabel: String,
    globalOutputSessionStartHelp: String,
    globalOutputSessionStopHelp: String,
    isWorkspaceSaveToolbarEnabled: Bool,
    updateProgramAudioGains: @escaping (ProgramPreferences) -> Void,
    reloadSavedProgramDefinitions: @escaping () -> Void,
    refreshCameras: @escaping () -> Void,
    deleteWorkspaceInputDevice: @escaping (String) -> Void,
    saveProgramDefinitionRecord: @escaping (SavedProgramDefinitionRecord) -> Bool,
    programDefinitionDirtyChanged: @escaping (Bool) -> Void,
    stopOutputSession: @escaping () -> Void,
    startOutputSession: @escaping () -> Void,
    pauseOutputSession: @escaping () -> Void,
    resetSession: @escaping () -> Void,
    addProgramDefinition: @escaping (String) -> Void,
    showProgramRenameDialog: @escaping () -> Void,
    renameSelectedProgramDefinitionFromDialog: @escaping () -> Void,
    deleteSelectedProgramDefinition: @escaping () -> Void,
    saveWorkspace: @escaping () -> Void,
    refreshExistingBroadcasts: @escaping () -> Void,
    manageYouTubeBroadcasts: @escaping () -> Void,
    chooseLocalOutputDirectory: @escaping () -> Void,
    analyzeVision: @escaping (WorkspaceVisionDefinition) -> Void,
    runAutomation: @escaping (WorkspaceAutomationDefinition) -> Void,
    captureFrame: @escaping () -> Void,
    openScreenshotsDirectory: @escaping () -> Void,
    featureAvailability: WorkspaceFeatureAvailability = .all
  ) {
    _selectedSidebarItem = selectedSidebarItem
    _selectedProgramDefinitionName = selectedProgramDefinitionName
    _workspaceInputDevices = workspaceInputDevices
    _workspaceAudioChannels = workspaceAudioChannels
    _visions = visions
    _automations = automations
    _compositeProgramDefinition = compositeProgramDefinition
    _programPreferences = programPreferences
    _saveProgramDefinitionCommand = saveProgramDefinitionCommand
    _programAddErrorMessage = programAddErrorMessage
    _presentedErrorDialog = presentedErrorDialog
    _isShowingProgramRenameDialog = isShowingProgramRenameDialog
    _proposedProgramName = proposedProgramName
    _captureFrameFeedback = captureFrameFeedback
    self.outputCanvas = outputCanvas
    self.outputDestination = outputDestination
    self.visionRuntimePresenter = visionRuntimePresenter
    self.backgroundRemovalPreprocessorFactory = backgroundRemovalPreprocessorFactory
    self.workspaceCaptureSessionCoordinator = workspaceCaptureSessionCoordinator
    self.activeProgramRuntime = activeProgramRuntime
    self.activeProgramSnapshot = activeProgramSnapshot
    self.selectedProgramDefinitionRecord = selectedProgramDefinitionRecord
    self.programRecords = programRecords
    self.activeProgramSelection = activeProgramSelection
    self.inputCameraDeviceMappings = inputCameraDeviceMappings
    self.audioPeakMeter = audioPeakMeter
    self.inputAudioPassthroughChannelKeys = inputAudioPassthroughChannelKeys
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
    self.outputSessionControlState = outputSessionControlState
    self.isOutputOperationLocked = isOutputOperationLocked
    self.canEditInputDevices = canEditInputDevices
    self.canEditOutputSettings = canEditOutputSettings
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
    self.pauseOutputSession = pauseOutputSession
    self.resetSession = resetSession
    self.addProgramDefinition = addProgramDefinition
    self.showProgramRenameDialog = showProgramRenameDialog
    self.renameSelectedProgramDefinitionFromDialog = renameSelectedProgramDefinitionFromDialog
    self.deleteSelectedProgramDefinition = deleteSelectedProgramDefinition
    self.saveWorkspace = saveWorkspace
    self.refreshExistingBroadcasts = refreshExistingBroadcasts
    self.manageYouTubeBroadcasts = manageYouTubeBroadcasts
    self.chooseLocalOutputDirectory = chooseLocalOutputDirectory
    self.analyzeVision = analyzeVision
    self.runAutomation = runAutomation
    self.captureFrame = captureFrame
    self.openScreenshotsDirectory = openScreenshotsDirectory
    self.featureAvailability = featureAvailability
  }

  public var body: some View {
    NavigationSplitView {
      WorkspaceSidebarPane(
        selectedSidebarItem: $selectedSidebarItem,
        workspaceInputDevices: $workspaceInputDevices,
        programPreferences: $programPreferences,
        visions: $visions,
        automations: $automations,
        isInputDeviceEditingEnabled: canEditInputDevices,
        featureAvailability: featureAvailability
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
        programPreferences: $programPreferences,
        workspaceInputDevices: workspaceInputDevices,
        workspaceAudioChannels: workspaceAudioChannels,
        inputCameraDeviceMappings: inputCameraDeviceMappings,
        audioPeakMeter: audioPeakMeter,
        inputAudioPassthroughChannelKeys: inputAudioPassthroughChannelKeys,
        updateProgramAudioGains: updateProgramAudioGains,
        programActions: programPreviewActions,
        captureFrameFeedback: $captureFrameFeedback
      )
    } detail: {
      workspaceDetailPane
        .toolbar {
          detailPrimaryActionToolbar
        }
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
    .sheet(isPresented: $isShowingAddProgramDialog) {
      ProgramNameDialog(
        name: $proposedNewProgramName,
        title: "Add Program",
        actionTitle: "Add",
        isNameAvailable: { candidate in
          !programRecords.contains { $0.name == candidate }
        },
        submit: {
          addProgramDefinition(proposedNewProgramName)
          isShowingAddProgramDialog = false
        },
        cancel: {
          isShowingAddProgramDialog = false
        }
      )
    }
    .alert(isPresented: errorDialogPresentedBinding) {
      guard let dialog = presentedErrorDialog else {
        return Alert(title: Text("Recording Stopped"))
      }
      return Alert(
        title: Text(dialog.title),
        message: Text(dialog.message),
        dismissButton: .cancel(Text("OK")) {
          presentedErrorDialog = nil
        }
      )
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
        },
        supportsBackgroundRemoval: featureAvailability.supportsBackgroundRemoval,
        backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory
      )
      .frame(width: 560, height: 720)
      .disabled(!canEditInputDevices)
    }
    .onAppear {
      outputCanvas.sync(from: selectedProgramDefinitionRecord)
    }
    .onChange(of: selectedProgramDefinitionRecord) { _, _ in
      outputCanvas.sync(from: selectedProgramDefinitionRecord)
    }
    .onChange(of: compositeProgramDefinition.steps.map(\.id)) { _, stepIDs in
      if case .some(.videoComponent(let id)) = selectedSidebarItem,
        !stepIDs.contains(id)
      {
        selectedSidebarItem = .streamSettings
      }
    }
    .onChange(of: workspaceInputDevices.map(\.id)) { _, inputDeviceIDs in
      if case .some(.inputDevice(let id)) = selectedSidebarItem,
        !inputDeviceIDs.contains(id)
      {
        selectedSidebarItem = .streamSettings
      }
      if let presentedInputDevicePreviewEditorID,
        !inputDeviceIDs.contains(presentedInputDevicePreviewEditorID)
      {
        self.presentedInputDevicePreviewEditorID = nil
      }
    }
    .onChange(of: visions.map(\.id)) { _, visionIDs in
      if case .some(.vision(let id)) = selectedSidebarItem, !visionIDs.contains(id) {
        selectedSidebarItem = .streamSettings
      }
    }
    .onChange(of: automations.map(\.id)) { _, automationIDs in
      if case .some(.automation(let id)) = selectedSidebarItem, !automationIDs.contains(id) {
        selectedSidebarItem = .streamSettings
      }
    }
    .frame(minWidth: 920, minHeight: 620)
  }

  private var errorDialogPresentedBinding: Binding<Bool> {
    Binding(
      get: { presentedErrorDialog != nil },
      set: { isPresented in
        if !isPresented { presentedErrorDialog = nil }
      }
    )
  }

  private var workspaceDetailPane: some View {
    WorkspaceDetailPane(
      selectedSidebarItem: $selectedSidebarItem,
      compositeProgramDefinition: $compositeProgramDefinition,
      outputCanvas: outputCanvas,
      workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
      workspaceInputDevices: $workspaceInputDevices,
      visions: $visions,
      automations: $automations,
      visionRuntimePresenter: visionRuntimePresenter,
      backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory,
      analyzeVision: analyzeVision,
      runAutomation: runAutomation,
      cameras: cameras,
      audioDevices: audioDevices,
      refreshCameras: refreshCameras,
      deleteWorkspaceInputDevice: deleteWorkspaceInputDevice,
      workspaceInputDeviceOptions: workspaceInputDevices,
      outputDestination: outputDestination,
      selectedProgramName: selectedProgramDefinitionName,
      outputSessionControlState: outputSessionControlState,
      isOutputOperationLocked: isOutputOperationLocked,
      isOutputSessionStartEnabled: isGlobalOutputSessionStartEnabled,
      outputSessionStartLabel: globalOutputSessionStartAccessibilityLabel,
      existingBroadcasts: existingBroadcasts,
      isLoadingBroadcasts: isLoadingBroadcasts,
      isConnectingBroadcast: isConnectingBroadcast,
      isStreamingToYouTube: isStreamingToYouTube,
      isRecording: isRecording,
      canSelectYouTubeBroadcast: canSelectYouTubeBroadcast,
      featureAvailability: featureAvailability,
      canEditInputDevices: canEditInputDevices,
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
      resetSession: resetSession,
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
  }

  @ToolbarContentBuilder
  private var outputSessionToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Button {
        stopOutputSession()
      } label: {
        Label("Stop", systemImage: "stop.fill")
      }
      .disabled(
        isOutputOperationLocked
          || outputSessionControlState == .idle
          || outputSessionControlState == .stopping
      )
      .help(globalOutputSessionStopHelp)
      .accessibilityLabel("Stop Output")
      .accessibilityIdentifier("toolbarStopOutputSessionButton")

      Button {
        switch outputSessionControlState {
        case .idle, .readyToRestart:
          startOutputSession()
        case .running:
          pauseOutputSession()
        case .starting, .pausing, .stopping:
          break
        }
      } label: {
        Label {
          Text(outputSessionControlState == .running ? "Pause" : "Start")
        } icon: {
          Image(systemName: outputSessionControlState == .running ? "pause.fill" : "play.fill")
        }
      }
      .disabled(isOutputOperationLocked || !isOutputSessionToggleEnabled)
      .help(outputSessionControlState == .running ? "Pause output." : globalOutputSessionStartHelp)
      .accessibilityLabel(
        outputSessionControlState == .running
          ? "Pause Output" : globalOutputSessionStartAccessibilityLabel
      )
      .accessibilityIdentifier("toolbarOutputSessionToggleButton")

      Button {
        resetSession()
      } label: {
        Label("Restart", systemImage: "arrow.clockwise")
      }
      .disabled(isOutputOperationLocked || isOutputSessionTransitioning)
      .help("Split the current recording and reconstruct its output session.")
      .accessibilityLabel("Restart Session")
      .accessibilityIdentifier("toolbarResetSessionButton")

      if isLoadingBroadcasts || isConnectingBroadcast {
        ProgressView()
          .controlSize(.small)
      }
    }
  }

  private var isOutputSessionToggleEnabled: Bool {
    switch outputSessionControlState {
    case .idle, .readyToRestart:
      isGlobalOutputSessionStartEnabled
    case .running:
      true
    case .starting, .pausing, .stopping:
      false
    }
  }

  private var isOutputSessionTransitioning: Bool {
    switch outputSessionControlState {
    case .starting, .pausing, .stopping:
      true
    case .idle, .running, .readyToRestart:
      false
    }
  }

  @ToolbarContentBuilder
  private var programManagementToolbar: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      ProgramSegmentedControl(
        programNames: programRecords.map(\.name),
        selection: activeProgramSelection
      )
      .accessibilityLabel("Program Selection")
      .accessibilityValue("Output is \(outputSessionStatusLabel)")
      .accessibilityIdentifier("activeProgramSegmentedControl")
      .background(programSelectionBackground.opacity(0.38), in: RoundedRectangle(cornerRadius: 6))
    }

    ToolbarItem(placement: .navigation) {
      Button {
        proposedNewProgramName = suggestedProgramName
        isShowingAddProgramDialog = true
      } label: {
        Label("Add Program", systemImage: "plus")
      }
      .help("Add Program")
      .accessibilityLabel("Add Program")
      .accessibilityIdentifier("toolbarAddProgramButton")
    }
  }

  private var programPreviewActions: ProgramPreviewActions? {
    guard let selectedProgramDefinitionName else { return nil }
    return ProgramPreviewActions(
      isShowingRenameDialog: $isShowingProgramRenameDialog,
      proposedProgramName: $proposedProgramName,
      currentName: selectedProgramDefinitionName,
      showRenameDialog: showProgramRenameDialog,
      renameProgram: renameSelectedProgramDefinitionFromDialog,
      deleteProgram: deleteSelectedProgramDefinition
    )
  }

  private var suggestedProgramName: String {
    programRecords.isEmpty ? "New Program" : "New Program \(programRecords.count + 1)"
  }

  private var outputSessionStatusLabel: String {
    switch outputSessionControlState {
    case .idle:
      "Stopped"
    case .starting, .pausing, .stopping:
      "Changing state"
    case .running:
      "Running"
    case .readyToRestart:
      "Paused"
    }
  }

  private var programSelectionBackground: Color {
    switch outputSessionControlState {
    case .idle:
      Color(red: 0.88, green: 0.91, blue: 0.97)
    case .starting, .pausing, .stopping:
      Color(red: 0.78, green: 0.89, blue: 0.98)
    case .running:
      Color(red: 0.78, green: 0.94, blue: 0.84)
    case .readyToRestart:
      Color(red: 0.89, green: 0.82, blue: 0.96)
    }
  }

  @ToolbarContentBuilder
  private var detailPrimaryActionToolbar: some ToolbarContent {
    ToolbarSpacer(.flexible, placement: .automatic)

    if case .some(.vision(let id)) = selectedSidebarItem,
      let vision = visions.first(where: { $0.id == id })
    {
      ToolbarItem(placement: .automatic) {
        Button {
          analyzeVision(vision)
        } label: {
          Label("Analyze", systemImage: "sparkles")
        }
        .disabled(
          !featureAvailability.supportsVision
            || isVisionBusy(visionRuntimePresenter.status(forVisionID: vision.id))
        )
        .help("Analyze Current Frame")
        .accessibilityLabel("Analyze Current Frame")
        .accessibilityIdentifier("toolbarAnalyzeVisionButton")
      }
    } else if case .some(.automation(let id)) = selectedSidebarItem,
      let automation = automations.first(where: { $0.id == id })
    {
      ToolbarItem(placement: .automatic) {
        Button {
          runAutomation(automation)
        } label: {
          Label("Run", systemImage: "play.fill")
        }
        .disabled(!featureAvailability.supportsAutomation || !automation.isEnabled)
        .help("Run Automation")
        .accessibilityLabel("Run Automation")
        .accessibilityIdentifier("toolbarRunAutomationButton")
      }
    }
  }

  private func isVisionBusy(_ status: VisionRuntimePresentationStatus) -> Bool {
    switch status {
    case .unavailable, .downloading, .analyzing:
      true
    default:
      false
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

private struct ProgramSegmentedControl: NSViewRepresentable {
  let programNames: [String]
  @Binding var selection: String?

  func makeCoordinator() -> Coordinator {
    Coordinator(selection: $selection)
  }

  func makeNSView(context: Context) -> NSSegmentedControl {
    let control = NSSegmentedControl()
    control.segmentStyle = .texturedRounded
    control.controlSize = .small
    control.trackingMode = .selectOne
    control.target = context.coordinator
    control.action = #selector(Coordinator.selectProgram(_:))
    control.setContentHuggingPriority(.required, for: .horizontal)
    control.setContentCompressionResistancePriority(.required, for: .horizontal)
    control.setAccessibilityIdentifier("activeProgramSegmentedControl")
    update(control)
    return control
  }

  func updateNSView(_ control: NSSegmentedControl, context: Context) {
    context.coordinator.selection = $selection
    update(control)
  }

  private func update(_ control: NSSegmentedControl) {
    control.segmentCount = programNames.count
    for (index, name) in programNames.enumerated() {
      control.setLabel(name, forSegment: index)
      control.setWidth(segmentWidth(for: name), forSegment: index)
      control.setSelected(name == selection, forSegment: index)
    }
    control.sizeToFit()
  }

  private func segmentWidth(for name: String) -> CGFloat {
    let measuringControl = NSSegmentedControl(
      labels: [name],
      trackingMode: .selectOne,
      target: nil,
      action: nil
    )
    measuringControl.segmentStyle = .texturedRounded
    measuringControl.controlSize = .small
    measuringControl.sizeToFit()
    return ceil(measuringControl.frame.width)
  }

  @MainActor
  final class Coordinator: NSObject {
    var selection: Binding<String?>

    init(selection: Binding<String?>) {
      self.selection = selection
    }

    @objc func selectProgram(_ sender: NSSegmentedControl) {
      guard sender.selectedSegment >= 0 else { return }
      selection.wrappedValue = sender.label(forSegment: sender.selectedSegment)
    }
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
  var supportsBackgroundRemoval: Bool
  var backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory?

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
        showsDeleteSection: false,
        supportsBackgroundRemoval: supportsBackgroundRemoval,
        backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory
      )
    }
    .accessibilityIdentifier("inputDevicePreviewEditorModal")
  }

  private var selectedInputDeviceName: String {
    guard let selectedInputDeviceID,
      let inputDevice = inputDevices.first(where: { $0.id == selectedInputDeviceID })
    else {
      return "Input Device"
    }
    return inputDevice.name
  }
}

extension ErrorDialogKind {
  fileprivate var title: LocalizedStringResource {
    switch self {
    case .outputSessionFailed:
      "Output Stopped"
    case .recordingAudioTrackUnavailable:
      "Recording Could Not Start"
    case .recordingWriterFailed:
      "Recording Stopped"
    case .recordingFinalizationFailed:
      "Recording Could Not Be Finalized"
    }
  }

  fileprivate var message: LocalizedStringResource {
    switch self {
    case .outputSessionFailed:
      "The output session encountered an error and was stopped. Check the log, correct the problem, then start a new session."
    case .recordingAudioTrackUnavailable:
      "A registered audio track could not be opened. The incomplete recording was preserved for inspection."
    case .recordingWriterFailed:
      "A media writer failed. The incomplete recording was preserved for recovery."
    case .recordingFinalizationFailed:
      "The recording could not be finalized. Its files were preserved for inspection."
    }
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
    @State private var visions: [WorkspaceVisionDefinition] = []
    @State private var automations: [WorkspaceAutomationDefinition] = []
    private let visionRuntimePresenter = LDTXAppUIPreviewVisionRuntimePresenter()
    @State private var compositeProgramDefinition = LDTXAppUIPreviewFixtures
      .compositeProgramDefinition
    @State private var programPreferences = LDTXAppUIPreviewFixtures.programPreferences
    @State private var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?
    @State private var programAddErrorMessage: String?
    @State private var isShowingProgramRenameDialog = false
    @State private var proposedProgramName = "Demo Program Copy"
    @State private var presentedErrorDialog: ErrorDialogKind?
    @State private var outputCanvas = LDTXAppUIPreviewFixtures.makeOutputCanvasModel()
    @State private var outputDestination = LDTXAppUIPreviewFixtures.makeOutputDestinationModel()
    private let workspaceCaptureSessionCoordinator =
      LDTXAppUIPreviewFixtures.makeWorkspaceCaptureSessionCoordinator()

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
        visions: $visions,
        automations: $automations,
        compositeProgramDefinition: $compositeProgramDefinition,
        programPreferences: $programPreferences,
        saveProgramDefinitionCommand: $saveProgramDefinitionCommand,
        programAddErrorMessage: $programAddErrorMessage,
        presentedErrorDialog: $presentedErrorDialog,
        isShowingProgramRenameDialog: $isShowingProgramRenameDialog,
        proposedProgramName: $proposedProgramName,
        captureFrameFeedback: .constant(nil),
        outputCanvas: outputCanvas,
        outputDestination: outputDestination,
        visionRuntimePresenter: visionRuntimePresenter,
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
        inputAudioPassthroughChannelKeys: .constant([]),
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
        outputSessionControlState: .idle,
        isOutputOperationLocked: false,
        canEditInputDevices: true,
        canEditOutputSettings: true,
        isGlobalOutputSessionStartEnabled: true,
        globalOutputSessionStartAccessibilityLabel: "Start Output",
        globalOutputSessionStartHelp: "Start streaming or recording",
        globalOutputSessionStopHelp: "Stop the current output session",
        isWorkspaceSaveToolbarEnabled: true,
        updateProgramAudioGains: { programPreferences = $0 },
        reloadSavedProgramDefinitions: {},
        refreshCameras: {},
        deleteWorkspaceInputDevice: { _ in },
        saveProgramDefinitionRecord: { _ in true },
        programDefinitionDirtyChanged: { _ in },
        stopOutputSession: {},
        startOutputSession: {},
        pauseOutputSession: {},
        resetSession: {},
        addProgramDefinition: { _ in },
        showProgramRenameDialog: {
          proposedProgramName = selectedProgramDefinitionName ?? ""
          isShowingProgramRenameDialog = true
        },
        renameSelectedProgramDefinitionFromDialog: {
          selectedProgramDefinitionName = proposedProgramName
          isShowingProgramRenameDialog = false
        },
        deleteSelectedProgramDefinition: {},
        saveWorkspace: {},
        refreshExistingBroadcasts: {},
        manageYouTubeBroadcasts: {},
        chooseLocalOutputDirectory: {},
        analyzeVision: { _ in },
        runAutomation: { _ in },
        captureFrame: {},
        openScreenshotsDirectory: {}
      )
    }
  }
#endif
