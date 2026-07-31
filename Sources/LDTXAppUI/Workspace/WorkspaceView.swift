// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXInternalProtocols
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
import SwiftUI

public enum OutputSessionControlState: Equatable, Sendable {
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
  @Binding private var videoComponents: [WorkspaceVideoComponentRecord]
  @Binding private var videoPTSMasterInputDeviceID: String?
  @Binding private var compositeProgramDefinition: CompositeProgramDefinition
  @Binding private var programPreferences: ProgramPreferences
  @Binding private var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?
  @Binding private var programAddErrorMessage: String?
  @Binding private var presentedErrorDialog: ErrorDialogKind?
  @Binding private var captureFrameFeedback: OutputFrameCaptureFeedback?
  private var requestWorkspaceResourceRename: (WorkspaceSidebarItem) -> Void
  private var isWorkspaceResourceRenameInProgress: Bool
  private var windowState: WorkspaceWindowState
  private var outputCanvas: OutputCanvasModel
  private var outputDestination: OutputDestination
  @Binding private var previewSettings: AppPreviewSettings
  private var visionRuntimePresenter: any VisionRuntimePresenting
  private var backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory?
  private var featureAvailability: WorkspaceFeatureAvailability

  private var workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  private var lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  /// Runtime for the Program selected in this Workspace window.
  private var selectedProgramRuntime: ProgramRuntime
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
  private var isGlobalOutputSessionStartEnabled: Bool
  private var globalOutputSessionStartAccessibilityLabel: String
  private var isWorkspaceSaveToolbarEnabled: Bool
  private var updateProgramAudioGains: (ProgramPreferences) -> Void
  private var reloadSavedProgramDefinitions: () -> Void
  private var refreshCameras: () -> Void
  private var deleteWorkspaceInputDevice: (String) -> Void
  private var deleteWorkspaceVideoComponent: (String) -> Void
  private var deleteWorkspaceVision: (String) -> Void
  private var saveProgramDefinitionRecord: (SavedProgramDefinitionRecord) -> Bool
  private var programDefinitionDirtyChanged: (Bool) -> Void
  private var stopOutputSession: () -> Void
  private var startOutputSession: () -> Void
  private var pauseOutputSession: () -> Void
  private var addProgramDefinition: (String) -> Void
  private var renameProgramDefinition: (String, String) -> Bool
  private var deleteProgramDefinition: (String) -> Void
  private var moveProgramDefinition: (String, Int) -> Void
  private var saveWorkspace: () -> Void
  private var refreshExistingBroadcasts: () -> Void
  private var manageYouTubeBroadcasts: () -> Void
  private var chooseOutputDirectory: () -> URL?
  private var applyOutputSettings: (OutputDestination) -> Void
  private var selectedBroadcastID: String?
  private var selectBroadcast: (String?) -> Void
  private var analyzeVision: (WorkspaceVisionDefinition) -> Void
  private var captureFrame: () -> Void
  private var openScreenshotsDirectory: () -> Void
  private var verifyRecording: () -> Void

  public init(
    selectedSidebarItem: Binding<WorkspaceSidebarItem?>,
    selectedProgramDefinitionName: Binding<String?>,
    workspaceInputDevices: Binding<[WorkspaceInputDeviceRecord]>,
    workspaceAudioChannels: Binding<[ProgramAudioChannel]>,
    visions: Binding<[WorkspaceVisionDefinition]>,
    videoComponents: Binding<[WorkspaceVideoComponentRecord]> = .constant([]),
    videoPTSMasterInputDeviceID: Binding<String?> = .constant(nil),
    compositeProgramDefinition: Binding<CompositeProgramDefinition>,
    programPreferences: Binding<ProgramPreferences>,
    saveProgramDefinitionCommand: Binding<ProgramDefinitionSaveCommand?>,
    programAddErrorMessage: Binding<String?>,
    presentedErrorDialog: Binding<ErrorDialogKind?>,
    captureFrameFeedback: Binding<OutputFrameCaptureFeedback?>,
    requestWorkspaceResourceRename: @escaping (WorkspaceSidebarItem) -> Void = { _ in },
    isWorkspaceResourceRenameInProgress: Bool = false,
    windowState: WorkspaceWindowState = WorkspaceWindowState(
      mode: .edit,
      outputSessionState: .idle,
      isOperationLocked: false
    ),
    outputCanvas: OutputCanvasModel,
    outputDestination: OutputDestination,
    previewSettings: Binding<AppPreviewSettings>,
    visionRuntimePresenter: any VisionRuntimePresenting,
    backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory? = nil,
    workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry,
    selectedProgramRuntime: ProgramRuntime,
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
    isGlobalOutputSessionStartEnabled: Bool,
    globalOutputSessionStartAccessibilityLabel: String,
    isWorkspaceSaveToolbarEnabled: Bool,
    updateProgramAudioGains: @escaping (ProgramPreferences) -> Void,
    reloadSavedProgramDefinitions: @escaping () -> Void,
    refreshCameras: @escaping () -> Void,
    deleteWorkspaceInputDevice: @escaping (String) -> Void,
    deleteWorkspaceVideoComponent: @escaping (String) -> Void = { _ in },
    deleteWorkspaceVision: @escaping (String) -> Void = { _ in },
    saveProgramDefinitionRecord: @escaping (SavedProgramDefinitionRecord) -> Bool,
    programDefinitionDirtyChanged: @escaping (Bool) -> Void,
    stopOutputSession: @escaping () -> Void,
    startOutputSession: @escaping () -> Void,
    pauseOutputSession: @escaping () -> Void,
    addProgramDefinition: @escaping (String) -> Void,
    renameProgramDefinition: @escaping (String, String) -> Bool,
    deleteProgramDefinition: @escaping (String) -> Void,
    moveProgramDefinition: @escaping (String, Int) -> Void,
    saveWorkspace: @escaping () -> Void,
    refreshExistingBroadcasts: @escaping () -> Void,
    manageYouTubeBroadcasts: @escaping () -> Void,
    chooseOutputDirectory: @escaping () -> URL? = { nil },
    applyOutputSettings: @escaping (OutputDestination) -> Void = { _ in },
    selectedBroadcastID: String? = nil,
    selectBroadcast: @escaping (String?) -> Void = { _ in },
    analyzeVision: @escaping (WorkspaceVisionDefinition) -> Void,
    captureFrame: @escaping () -> Void,
    openScreenshotsDirectory: @escaping () -> Void,
    verifyRecording: @escaping () -> Void = {},
    featureAvailability: WorkspaceFeatureAvailability = .all
  ) {
    _selectedSidebarItem = selectedSidebarItem
    _selectedProgramDefinitionName = selectedProgramDefinitionName
    _workspaceInputDevices = workspaceInputDevices
    _workspaceAudioChannels = workspaceAudioChannels
    _visions = visions
    _videoComponents = videoComponents
    _videoPTSMasterInputDeviceID = videoPTSMasterInputDeviceID
    _compositeProgramDefinition = compositeProgramDefinition
    _programPreferences = programPreferences
    _saveProgramDefinitionCommand = saveProgramDefinitionCommand
    _programAddErrorMessage = programAddErrorMessage
    _presentedErrorDialog = presentedErrorDialog
    _captureFrameFeedback = captureFrameFeedback
    self.requestWorkspaceResourceRename = requestWorkspaceResourceRename
    self.isWorkspaceResourceRenameInProgress = isWorkspaceResourceRenameInProgress
    self.windowState = windowState
    self.outputCanvas = outputCanvas
    self.outputDestination = outputDestination
    _previewSettings = previewSettings
    self.visionRuntimePresenter = visionRuntimePresenter
    self.backgroundRemovalPreprocessorFactory = backgroundRemovalPreprocessorFactory
    self.workspaceCaptureSessionCoordinator = workspaceCaptureSessionCoordinator
    self.lowFrequencyUpdateRegistry = lowFrequencyUpdateRegistry
    self.selectedProgramRuntime = selectedProgramRuntime
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
    self.isGlobalOutputSessionStartEnabled = isGlobalOutputSessionStartEnabled
    self.globalOutputSessionStartAccessibilityLabel = globalOutputSessionStartAccessibilityLabel
    self.isWorkspaceSaveToolbarEnabled = isWorkspaceSaveToolbarEnabled
    self.updateProgramAudioGains = updateProgramAudioGains
    self.reloadSavedProgramDefinitions = reloadSavedProgramDefinitions
    self.refreshCameras = refreshCameras
    self.deleteWorkspaceInputDevice = deleteWorkspaceInputDevice
    self.deleteWorkspaceVideoComponent = deleteWorkspaceVideoComponent
    self.deleteWorkspaceVision = deleteWorkspaceVision
    self.saveProgramDefinitionRecord = saveProgramDefinitionRecord
    self.programDefinitionDirtyChanged = programDefinitionDirtyChanged
    self.stopOutputSession = stopOutputSession
    self.startOutputSession = startOutputSession
    self.pauseOutputSession = pauseOutputSession
    self.addProgramDefinition = addProgramDefinition
    self.renameProgramDefinition = renameProgramDefinition
    self.deleteProgramDefinition = deleteProgramDefinition
    self.moveProgramDefinition = moveProgramDefinition
    self.saveWorkspace = saveWorkspace
    self.refreshExistingBroadcasts = refreshExistingBroadcasts
    self.manageYouTubeBroadcasts = manageYouTubeBroadcasts
    self.chooseOutputDirectory = chooseOutputDirectory
    self.applyOutputSettings = applyOutputSettings
    self.selectedBroadcastID = selectedBroadcastID
    self.selectBroadcast = selectBroadcast
    self.analyzeVision = analyzeVision
    self.captureFrame = captureFrame
    self.openScreenshotsDirectory = openScreenshotsDirectory
    self.verifyRecording = verifyRecording
    self.featureAvailability = featureAvailability
  }

  public var body: some View {
    navigationLayout
    .background {
      ProgramDefinitionEditorCoordinator(
        selectedProgramDefinitionName: $selectedProgramDefinitionName,
        compositeProgramDefinition: $compositeProgramDefinition,
        workspaceInputDevices: $workspaceInputDevices,
        workspaceVideoComponents: videoComponents,
        programPreferences: $programPreferences,
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
      if selectedSidebarItem == .programs {
        ToolbarItem(placement: .principal) {
          Text("Manage Programs")
            .font(.headline)
        }
      } else {
        workspaceToolbar
      }
    }
    .alert("Program Could Not Be Added", isPresented: programAddErrorPresentedBinding) {
      Button("OK", role: .cancel) {
        programAddErrorMessage = nil
      }
    } message: {
      Text(programAddErrorMessage ?? "")
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
    .onChange(of: videoComponents.map(\.id)) { _, componentIDs in
      if case .some(.videoComponent(let id)) = selectedSidebarItem,
        !componentIDs.contains(id)
      {
        selectedSidebarItem = .output
      }
    }
    .onChange(of: workspaceInputDevices.map(\.id)) { _, inputDeviceIDs in
      if case .some(.inputDevice(let id)) = selectedSidebarItem,
        !inputDeviceIDs.contains(id)
      {
        selectedSidebarItem = .output
      }
    }
    .onChange(of: visions.map(\.id)) { _, visionIDs in
      if case .some(.vision(let id)) = selectedSidebarItem, !visionIDs.contains(id) {
        selectedSidebarItem = .output
      }
    }
    .frame(minWidth: 920, minHeight: 620)
    .disabled(isWorkspaceResourceRenameInProgress)
  }

  private var navigationLayout: some View {
    NavigationSplitView {
      workspaceSidebar
    } content: {
      workspaceContentPane
    } detail: {
      workspaceDetailPane
        .toolbar {
          if selectedSidebarItem != .programs {
            detailPrimaryActionToolbar
          }
        }
    }
  }

  private var workspaceSidebar: some View {
    WorkspaceSidebarPane(
      selectedSidebarItem: $selectedSidebarItem,
      workspaceInputDevices: $workspaceInputDevices,
      programPreferences: $programPreferences,
      visions: $visions,
      videoComponents: $videoComponents,
      windowState: windowState,
      featureAvailability: featureAvailability,
      cameras: cameras,
      audioDevices: audioDevices
    )
  }

  private var workspaceContentPane: some View {
    WorkspaceContentPane(
      selectedSidebarItem: $selectedSidebarItem,
      selectedProgramDefinitionName: selectedProgramDefinitionName,
      compositeProgramDefinition: $compositeProgramDefinition,
      outputCanvas: outputCanvas,
      previewSettings: $previewSettings,
      workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
      lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
      selectedProgramRuntime: selectedProgramRuntime,
      selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
      programPreferences: $programPreferences,
      workspaceInputDevices: workspaceInputDevices,
      workspaceVideoComponents: videoComponents,
      backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory,
      supportsBackgroundRemoval: featureAvailability.supportsBackgroundRemoval,
      workspaceAudioChannels: workspaceAudioChannels,
      inputCameraDeviceMappings: inputCameraDeviceMappings,
      audioPeakMeter: audioPeakMeter,
      inputAudioPassthroughChannelKeys: inputAudioPassthroughChannelKeys,
      updateProgramAudioGains: updateProgramAudioGains,
      windowState: windowState,
      captureFrameFeedback: $captureFrameFeedback,
      programRecords: programRecords,
      addProgram: addProgramDefinition,
      renameProgram: renameProgramDefinition,
      deleteProgram: deleteProgramDefinition,
      moveProgram: moveProgramDefinition
    )
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
      programPreferences: $programPreferences,
      outputCanvas: outputCanvas,
      workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
      lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
      workspaceInputDevices: $workspaceInputDevices,
      visions: $visions,
      videoComponents: $videoComponents,
      videoPTSMasterInputDeviceID: $videoPTSMasterInputDeviceID,
      visionRuntimePresenter: visionRuntimePresenter,
      backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory,
      analyzeVision: analyzeVision,
      cameras: cameras,
      audioDevices: audioDevices,
      refreshCameras: refreshCameras,
      deleteWorkspaceInputDevice: deleteWorkspaceInputDevice,
      deleteWorkspaceVideoComponent: deleteWorkspaceVideoComponent,
      deleteWorkspaceVision: deleteWorkspaceVision,
      workspaceInputDeviceOptions: workspaceInputDevices,
      outputDestination: outputDestination,
      selectedBroadcastID: selectedBroadcastID,
      selectedProgramName: selectedProgramDefinitionName,
      windowState: windowState,
      isOutputSessionStartEnabled: isGlobalOutputSessionStartEnabled,
      outputSessionStartLabel: globalOutputSessionStartAccessibilityLabel,
      showsOutputSessionControls: windowState.mode == .output,
      existingBroadcasts: existingBroadcasts,
      isLoadingBroadcasts: isLoadingBroadcasts,
      featureAvailability: featureAvailability,
      refreshExistingBroadcasts: refreshExistingBroadcasts,
      manageYouTubeBroadcasts: manageYouTubeBroadcasts,
      chooseOutputDirectory: chooseOutputDirectory,
      applyOutputSettings: applyOutputSettings,
      selectBroadcast: selectBroadcast,
      captureFrame: captureFrame,
      openScreenshotsDirectory: openScreenshotsDirectory,
      verifyRecording: verifyRecording,
      startOutputSession: startOutputSession,
      pauseOutputSession: pauseOutputSession,
      stopOutputSession: stopOutputSession
    )
  }

  @ToolbarContentBuilder
  private var workspaceToolbar: some ToolbarContent {
    outputSessionToolbar
    programSwitcherToolbar
  }

  @ToolbarContentBuilder
  private var outputSessionToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Button(role: .destructive, action: stopOutputSession) {
        Label("Stop", systemImage: "stop.fill")
      }
        .disabled(!canUseToolbarStop)
        .help("Stop Output")
        .accessibilityLabel("Stop Output")
        .accessibilityIdentifier("toolbarStopOutputSessionButton")
      if windowState.outputSessionState == .running {
        Button(action: pauseOutputSession) {
          Label("Pause", systemImage: "pause.fill")
        }
          .disabled(windowState.isOperationLocked)
          .help("Pause Output")
          .accessibilityLabel("Pause Output")
          .accessibilityIdentifier("toolbarOutputSessionToggleButton")
      } else {
        Button(action: startOutputSession) {
          Label("Start", systemImage: "play.fill")
        }
          .disabled(!canUseToolbarStart)
          .help(globalOutputSessionStartAccessibilityLabel)
          .accessibilityLabel(globalOutputSessionStartAccessibilityLabel)
          .accessibilityIdentifier("toolbarOutputSessionToggleButton")
      }
    }
  }

  private var canUseToolbarStart: Bool {
    guard isGlobalOutputSessionStartEnabled else { return false }
    return windowState.outputSessionState == .idle || windowState.outputSessionState == .readyToRestart
  }

  private var canUseToolbarStop: Bool {
    return windowState.outputSessionState == .running || windowState.outputSessionState == .readyToRestart
  }

  @ToolbarContentBuilder
  private var programSwitcherToolbar: some ToolbarContent {
    ToolbarSpacer(.fixed, placement: .navigation)

    ToolbarItem(placement: .navigation) {
      WorkspaceProgramSwitcher(
        programNames: programRecords.map(\.name),
        selection: activeProgramSelection,
        state: windowState.outputSessionState,
        isProgramRuntimeTransitioning: windowState.isProgramRuntimeTransitioning,
        isSelectionEnabled: windowState.mode == .edit || canChangeProgramDuringOutput
      )
    }

  }

  private var canChangeProgramDuringOutput: Bool {
    guard !windowState.isProgramRuntimeTransitioning else { return false }
    return switch windowState.outputSessionState {
    case .starting, .pausing, .stopping:
      false
    case .idle, .running, .readyToRestart:
      true
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
            || windowState.isOperationLocked
            || windowState.outputSessionState != .running
            || vision.updateIntervalSeconds != nil
            || isVisionBusy(visionRuntimePresenter.status(forVisionID: vision.id))
        )
        .help(
          vision.updateIntervalSeconds != nil
            ? "Periodic analysis is enabled"
            : windowState.outputSessionState == .running
              ? "Analyze Current Frame" : "Start the Session to analyze"
        )
        .accessibilityLabel("Analyze Current Frame")
        .accessibilityIdentifier("toolbarAnalyzeVisionButton")
      }
    }

    if let renameTarget = selectedSidebarItem, canRename(renameTarget) {
      ToolbarItem(placement: .automatic) {
        Button("Rename…") {
          requestWorkspaceResourceRename(renameTarget)
        }
        .accessibilityIdentifier("renameWorkspaceResourceButton")
      }
    }
  }

  private func canRename(_ item: WorkspaceSidebarItem) -> Bool {
    guard windowState.mode == .edit, !windowState.isOperationLocked else { return false }
    return switch item {
    case .inputDevice, .videoComponent, .vision:
      true
    case .output, .canvas, .videoLayers, .programs:
      false
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

struct WorkspaceProgramSwitcher: View {
  let programNames: [String]
  @Binding var selection: String?
  let state: OutputSessionControlState
  let isProgramRuntimeTransitioning: Bool
  let isSelectionEnabled: Bool

  var body: some View {
    ProgramSegmentedControl(
      programNames: programNames,
      selection: $selection,
      isEnabled: isSelectionEnabled
    )
      .accessibilityLabel("Program Switcher")
      .accessibilityValue("Output is \(statusLabel)")
      .accessibilityIdentifier("programSwitcher")
      .help("Program Switcher")
  }

  private var statusLabel: String {
    if isProgramRuntimeTransitioning { return "Switching Program" }
    return switch state {
    case .idle: "Stopped"
    case .starting, .pausing, .stopping: "Changing state"
    case .running: "Running"
    case .readyToRestart: "Paused"
    }
  }

}

private struct ProgramSegmentedControl: NSViewRepresentable {
  let programNames: [String]
  @Binding var selection: String?
  let isEnabled: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(selection: $selection)
  }

  func makeNSView(context: Context) -> NSSegmentedControl {
    let control = NSSegmentedControl()
    control.segmentStyle = .texturedRounded
    control.selectedSegmentBezelColor = .controlAccentColor
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
    control.isEnabled = isEnabled
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
    private let visionRuntimePresenter = LDTXAppUIPreviewVisionRuntimePresenter()
    @State private var compositeProgramDefinition = LDTXAppUIPreviewFixtures
      .compositeProgramDefinition
    @State private var programPreferences = LDTXAppUIPreviewFixtures.programPreferences
    @State private var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?
    @State private var programAddErrorMessage: String?
    @State private var presentedErrorDialog: ErrorDialogKind?
    @State private var outputCanvas = LDTXAppUIPreviewFixtures.makeOutputCanvasModel()
    @State private var outputDestination = OutputDestination.newWorkspaceInitialValue
    @State private var previewSettings = LDTXAppUIPreviewFixtures.makeAppPreviewSettings()
    private let workspaceCaptureSessionCoordinator =
      LDTXAppUIPreviewFixtures.makeWorkspaceCaptureSessionCoordinator()
    private let lowFrequencyUpdateRegistry = LowFrequencyUpdateRegistry()

    private var previewRuntime: ProgramRuntime {
      LDTXAppUIPreviewFixtures.makeProgramRuntime(
        coordinator: workspaceCaptureSessionCoordinator,
        lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry
      )
    }

    var body: some View {
      WorkspaceView(
        selectedSidebarItem: $selectedSidebarItem,
        selectedProgramDefinitionName: $selectedProgramDefinitionName,
        workspaceInputDevices: $workspaceInputDevices,
        workspaceAudioChannels: $workspaceAudioChannels,
        visions: $visions,
        compositeProgramDefinition: $compositeProgramDefinition,
        programPreferences: $programPreferences,
        saveProgramDefinitionCommand: $saveProgramDefinitionCommand,
        programAddErrorMessage: $programAddErrorMessage,
        presentedErrorDialog: $presentedErrorDialog,
        captureFrameFeedback: .constant(nil),
        windowState: WorkspaceWindowState(
          mode: .edit,
          outputSessionState: .idle,
          isOperationLocked: false
        ),
        outputCanvas: outputCanvas,
        outputDestination: outputDestination,
        previewSettings: $previewSettings,
        visionRuntimePresenter: visionRuntimePresenter,
        workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
        lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
        selectedProgramRuntime: previewRuntime,
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
        isGlobalOutputSessionStartEnabled: true,
        globalOutputSessionStartAccessibilityLabel: "Start Output",
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
        addProgramDefinition: { _ in },
        renameProgramDefinition: { _, _ in true },
        deleteProgramDefinition: { _ in },
        moveProgramDefinition: { _, _ in },
        saveWorkspace: {},
        refreshExistingBroadcasts: {},
        manageYouTubeBroadcasts: {},
        analyzeVision: { _ in },
        captureFrame: {},
        openScreenshotsDirectory: {}
      )
    }
  }
#endif
