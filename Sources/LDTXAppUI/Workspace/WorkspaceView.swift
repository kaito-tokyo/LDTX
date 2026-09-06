// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXInternalProtocols
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
import LDTXYouTubeRTMPS
import SwiftUI

public enum OutputSessionControlState: Equatable, Sendable {
  case idle
  case starting
  case running
  case pausing
  case readyToRestart
  case stopping
}

public enum WorkspacePane { case sidebar, content, inspector }

public struct WorkspaceView: View {
  private var displayedPane: WorkspacePane = .content

  public func pane(_ pane: WorkspacePane) -> Self {
    var copy = self
    copy.displayedPane = pane
    return copy
  }
  @Binding private var activeProgramCanvasRole: ProgramCanvasRole
  @Binding private var selectedSidebarItem: WorkspaceSidebarItem?
  @Binding private var selectedProgramDefinitionName: String?
  @Binding private var workspaceInputDevices: [WorkspaceInputDeviceRecord]
  @Binding private var workspaceAudioChannels: [ProgramAudioChannel]
  @Binding private var visions: [WorkspaceVisionDefinition]
  @Binding private var videoComponents: [WorkspaceVideoComponentRecord]
  @Binding private var videoPTSMasterInputDeviceID: String?
  @Binding private var compositeProgramDefinition: CompositeProgramDefinition
  @Binding private var portraitCompositeProgramDefinition: CompositeProgramDefinition
  @Binding private var programPreferences: ProgramPreferences
  @Binding private var portraitProgramPreferences: ProgramPreferences
  @Binding private var captureFrameFeedback: OutputFrameCaptureFeedback?
  private var requestWorkspaceResourceRename: (WorkspaceSidebarItem) -> Void
  private var isWorkspaceResourceRenameInProgress: Bool
  private var windowState: WorkspaceWindowState
  private var outputCanvas: OutputCanvasModel
  private var landscapeVideoBitRate: Int
  private var portraitVideoBitRate: Int
  private var outputDestination: OutputDestination
  @Binding private var previewSettings: AppPreviewSettings
  private var visionRuntimePresenter: any VisionRuntimePresenting
  private var backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory?
  private var featureAvailability: WorkspaceFeatureAvailability

  private var workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  private var lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  /// Runtime for the Program selected in this Workspace window.
  private var selectedProgramRuntime: ProgramRuntime
  private var selectedPortraitProgramRuntime: ProgramRuntime
  private var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
  private var programRecords: [SavedProgramDefinitionRecord]
  private var activeProgramSelection: Binding<String?>
  private var inputCameraDeviceMappings: [String: String]
  private var audioPeakMeter: ProgramAudioPeakMeter
  private var inputAudioPassthroughChannelKeys: Binding<Set<String>>
  private var cameras: [InputPhysicalDeviceOption]
  private var audioDevices: [InputPhysicalDeviceOption]
  private var existingBroadcasts: [LiveBroadcastSummary]
  private var existingLiveStreams: [LiveStreamSummary]
  private var isLoadingBroadcasts: Bool
  private var isGlobalOutputSessionStartEnabled: Bool
  private var globalOutputSessionStartAccessibilityLabel: String
  private var refreshCameras: () -> Void
  private var deleteWorkspaceInputDevice: (String) -> Void
  private var deleteWorkspaceVideoComponent: (String) -> Void
  private var deleteWorkspaceVision: (String) -> Void
  private var stopOutputSession: () -> Void
  private var startOutputSession: () -> Void
  private var pauseOutputSession: () -> Void
  private var addProgramDefinition: (String) -> Void
  private var renameProgramDefinition: (String, String) -> Bool
  private var deleteProgramDefinition: (String) -> Void
  private var moveProgramDefinition: (String, Int) -> Void
  private var refreshExistingBroadcasts: () -> Void
  private var streamKeyConfigurations: [YouTubeRTMPSStreamKeyConfiguration] = []
  private var saveStreamKeyConfigurations: ([YouTubeRTMPSStreamKeyConfiguration]) throws -> Void = {
    _ in
  }
  private var importStreamKeyConfiguration:
    (String) async throws -> YouTubeRTMPSStreamKeyConfiguration = { _ in
      throw YouTubeRTMPSError.invalidDestination
    }
  private var refreshExistingLiveStreams: () -> Void
  private var manageYouTubeBroadcasts: () -> Void
  private var chooseOutputDirectory: () -> URL?
  private var applyOutputSettings: (OutputDestination) -> Void
  private var selectedBroadcastID: String?
  private var selectBroadcast: (String?) -> Void
  private var selectedLandscapeLiveStreamID: String?
  private var selectedPortraitLiveStreamID: String?
  private var selectLandscapeLiveStream: (String?) -> Void
  private var selectPortraitLiveStream: (String?) -> Void
  private var analyzeVision: (WorkspaceVisionDefinition) -> Void
  private var captureFrame: () -> Void
  private var cutRecording: () -> Void
  private var openYouTubeStreamConsole: () -> Void
  private var openYouTubeLiveChat: () -> Void
  private var openYouTubeLiveControlRoom: () -> Void
  private var openScreenshotsDirectory: () -> Void
  private var verifyRecording: () -> Void

  public init(
    activeProgramCanvasRole: Binding<ProgramCanvasRole> = .constant(.landscape),
    selectedSidebarItem: Binding<WorkspaceSidebarItem?>,
    selectedProgramDefinitionName: Binding<String?>,
    workspaceInputDevices: Binding<[WorkspaceInputDeviceRecord]>,
    workspaceAudioChannels: Binding<[ProgramAudioChannel]>,
    visions: Binding<[WorkspaceVisionDefinition]>,
    videoComponents: Binding<[WorkspaceVideoComponentRecord]> = .constant([]),
    videoPTSMasterInputDeviceID: Binding<String?> = .constant(nil),
    compositeProgramDefinition: Binding<CompositeProgramDefinition>,
    portraitCompositeProgramDefinition: Binding<CompositeProgramDefinition>,
    programPreferences: Binding<ProgramPreferences>,
    portraitProgramPreferences: Binding<ProgramPreferences>,
    captureFrameFeedback: Binding<OutputFrameCaptureFeedback?>,
    requestWorkspaceResourceRename: @escaping (WorkspaceSidebarItem) -> Void = { _ in },
    isWorkspaceResourceRenameInProgress: Bool = false,
    windowState: WorkspaceWindowState = WorkspaceWindowState(
      mode: .edit,
      outputSessionState: .idle,
      isOperationLocked: false
    ),
    outputCanvas: OutputCanvasModel,
    landscapeVideoBitRate: Int = 6_000_000,
    portraitVideoBitRate: Int = 6_000_000,
    outputDestination: OutputDestination,
    previewSettings: Binding<AppPreviewSettings>,
    visionRuntimePresenter: any VisionRuntimePresenting,
    backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory? = nil,
    workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry,
    selectedProgramRuntime: ProgramRuntime,
    selectedPortraitProgramRuntime: ProgramRuntime,
    selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?,
    programRecords: [SavedProgramDefinitionRecord],
    activeProgramSelection: Binding<String?>,
    inputCameraDeviceMappings: [String: String],
    audioPeakMeter: ProgramAudioPeakMeter,
    inputAudioPassthroughChannelKeys: Binding<Set<String>>,
    cameras: [InputPhysicalDeviceOption],
    audioDevices: [InputPhysicalDeviceOption],
    existingBroadcasts: [LiveBroadcastSummary],
    existingLiveStreams: [LiveStreamSummary] = [],
    isLoadingBroadcasts: Bool,
    isGlobalOutputSessionStartEnabled: Bool,
    globalOutputSessionStartAccessibilityLabel: String,
    refreshCameras: @escaping () -> Void,
    deleteWorkspaceInputDevice: @escaping (String) -> Void,
    deleteWorkspaceVideoComponent: @escaping (String) -> Void = { _ in },
    deleteWorkspaceVision: @escaping (String) -> Void = { _ in },
    stopOutputSession: @escaping () -> Void,
    startOutputSession: @escaping () -> Void,
    pauseOutputSession: @escaping () -> Void,
    addProgramDefinition: @escaping (String) -> Void,
    renameProgramDefinition: @escaping (String, String) -> Bool,
    deleteProgramDefinition: @escaping (String) -> Void,
    moveProgramDefinition: @escaping (String, Int) -> Void,
    refreshExistingBroadcasts: @escaping () -> Void,
    streamKeyConfigurations: [YouTubeRTMPSStreamKeyConfiguration] = [],
    saveStreamKeyConfigurations: @escaping ([YouTubeRTMPSStreamKeyConfiguration]) throws -> Void = {
      _ in
    },
    importStreamKeyConfiguration:
      @escaping (String) async throws -> YouTubeRTMPSStreamKeyConfiguration = { _ in
        throw YouTubeRTMPSError.invalidDestination
      },
    refreshExistingLiveStreams: @escaping () -> Void = {},
    manageYouTubeBroadcasts: @escaping () -> Void,
    chooseOutputDirectory: @escaping () -> URL? = { nil },
    applyOutputSettings: @escaping (OutputDestination) -> Void = { _ in },
    selectedBroadcastID: String? = nil,
    selectBroadcast: @escaping (String?) -> Void = { _ in },
    selectedLandscapeLiveStreamID: String? = nil,
    selectedPortraitLiveStreamID: String? = nil,
    selectLandscapeLiveStream: @escaping (String?) -> Void = { _ in },
    selectPortraitLiveStream: @escaping (String?) -> Void = { _ in },
    analyzeVision: @escaping (WorkspaceVisionDefinition) -> Void,
    captureFrame: @escaping () -> Void,
    cutRecording: @escaping () -> Void = {},
    openYouTubeStreamConsole: @escaping () -> Void = {},
    openYouTubeLiveChat: @escaping () -> Void = {},
    openYouTubeLiveControlRoom: @escaping () -> Void = {},
    openScreenshotsDirectory: @escaping () -> Void,
    verifyRecording: @escaping () -> Void = {},
    featureAvailability: WorkspaceFeatureAvailability = .all
  ) {
    _activeProgramCanvasRole = activeProgramCanvasRole
    _selectedSidebarItem = selectedSidebarItem
    _selectedProgramDefinitionName = selectedProgramDefinitionName
    _workspaceInputDevices = workspaceInputDevices
    _workspaceAudioChannels = workspaceAudioChannels
    _visions = visions
    _videoComponents = videoComponents
    _videoPTSMasterInputDeviceID = videoPTSMasterInputDeviceID
    _compositeProgramDefinition = compositeProgramDefinition
    _portraitCompositeProgramDefinition = portraitCompositeProgramDefinition
    _programPreferences = programPreferences
    _portraitProgramPreferences = portraitProgramPreferences
    _captureFrameFeedback = captureFrameFeedback
    self.requestWorkspaceResourceRename = requestWorkspaceResourceRename
    self.isWorkspaceResourceRenameInProgress = isWorkspaceResourceRenameInProgress
    self.windowState = windowState
    self.outputCanvas = outputCanvas
    self.landscapeVideoBitRate = landscapeVideoBitRate
    self.portraitVideoBitRate = portraitVideoBitRate
    self.outputDestination = outputDestination
    _previewSettings = previewSettings
    self.visionRuntimePresenter = visionRuntimePresenter
    self.backgroundRemovalPreprocessorFactory = backgroundRemovalPreprocessorFactory
    self.workspaceCaptureSessionCoordinator = workspaceCaptureSessionCoordinator
    self.lowFrequencyUpdateRegistry = lowFrequencyUpdateRegistry
    self.selectedProgramRuntime = selectedProgramRuntime
    self.selectedPortraitProgramRuntime = selectedPortraitProgramRuntime
    self.selectedProgramDefinitionRecord = selectedProgramDefinitionRecord
    self.programRecords = programRecords
    self.activeProgramSelection = activeProgramSelection
    self.inputCameraDeviceMappings = inputCameraDeviceMappings
    self.audioPeakMeter = audioPeakMeter
    self.inputAudioPassthroughChannelKeys = inputAudioPassthroughChannelKeys
    self.cameras = cameras
    self.audioDevices = audioDevices
    self.existingBroadcasts = existingBroadcasts
    self.existingLiveStreams = existingLiveStreams
    self.isLoadingBroadcasts = isLoadingBroadcasts
    self.isGlobalOutputSessionStartEnabled = isGlobalOutputSessionStartEnabled
    self.globalOutputSessionStartAccessibilityLabel = globalOutputSessionStartAccessibilityLabel
    self.refreshCameras = refreshCameras
    self.deleteWorkspaceInputDevice = deleteWorkspaceInputDevice
    self.deleteWorkspaceVideoComponent = deleteWorkspaceVideoComponent
    self.deleteWorkspaceVision = deleteWorkspaceVision
    self.stopOutputSession = stopOutputSession
    self.startOutputSession = startOutputSession
    self.pauseOutputSession = pauseOutputSession
    self.addProgramDefinition = addProgramDefinition
    self.renameProgramDefinition = renameProgramDefinition
    self.deleteProgramDefinition = deleteProgramDefinition
    self.moveProgramDefinition = moveProgramDefinition
    self.refreshExistingBroadcasts = refreshExistingBroadcasts
    self.streamKeyConfigurations = streamKeyConfigurations
    self.saveStreamKeyConfigurations = saveStreamKeyConfigurations
    self.importStreamKeyConfiguration = importStreamKeyConfiguration
    self.refreshExistingLiveStreams = refreshExistingLiveStreams
    self.manageYouTubeBroadcasts = manageYouTubeBroadcasts
    self.chooseOutputDirectory = chooseOutputDirectory
    self.applyOutputSettings = applyOutputSettings
    self.selectedBroadcastID = selectedBroadcastID
    self.selectBroadcast = selectBroadcast
    self.selectedLandscapeLiveStreamID = selectedLandscapeLiveStreamID
    self.selectedPortraitLiveStreamID = selectedPortraitLiveStreamID
    self.selectLandscapeLiveStream = selectLandscapeLiveStream
    self.selectPortraitLiveStream = selectPortraitLiveStream
    self.analyzeVision = analyzeVision
    self.captureFrame = captureFrame
    self.cutRecording = cutRecording
    self.openYouTubeStreamConsole = openYouTubeStreamConsole
    self.openYouTubeLiveChat = openYouTubeLiveChat
    self.openYouTubeLiveControlRoom = openYouTubeLiveControlRoom
    self.openScreenshotsDirectory = openScreenshotsDirectory
    self.verifyRecording = verifyRecording
    self.featureAvailability = featureAvailability
  }

  public var body: some View {
    navigationLayout
      .frame(minHeight: 620)
      .disabled(isWorkspaceResourceRenameInProgress)
  }

  @ViewBuilder
  private var navigationLayout: some View {
    switch displayedPane {
    case .sidebar: workspaceSidebar
    case .content: workspaceContentPane
    case .inspector: workspaceDetailPane
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
      portraitCompositeProgramDefinition: $portraitCompositeProgramDefinition,
      outputCanvas: outputCanvas,
      previewSettings: $previewSettings,
      workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
      lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
      selectedProgramRuntime: selectedProgramRuntime,
      selectedPortraitProgramRuntime: selectedPortraitProgramRuntime,
      selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
      programPreferences: $programPreferences,
      portraitProgramPreferences: $portraitProgramPreferences,
      activeProgramCanvasRole: $activeProgramCanvasRole,
      workspaceInputDevices: workspaceInputDevices,
      workspaceVideoComponents: videoComponents,
      backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory,
      supportsBackgroundRemoval: featureAvailability.supportsBackgroundRemoval,
      workspaceAudioChannels: $workspaceAudioChannels,
      inputCameraDeviceMappings: inputCameraDeviceMappings,
      audioPeakMeter: audioPeakMeter,
      inputAudioPassthroughChannelKeys: inputAudioPassthroughChannelKeys,
      windowState: windowState,
      captureFrameFeedback: $captureFrameFeedback,
      programRecords: programRecords,
      addProgram: addProgramDefinition,
      renameProgram: renameProgramDefinition,
      deleteProgram: deleteProgramDefinition,
      moveProgram: moveProgramDefinition,
    )
  }

  private var workspaceDetailPane: some View {
    WorkspaceDetailPane(
      selectedSidebarItem: $selectedSidebarItem,
      compositeProgramDefinition: activeProgramCanvasRole == .landscape
        ? $compositeProgramDefinition : $portraitCompositeProgramDefinition,
      programPreferences: activeProgramCanvasRole == .landscape
        ? $programPreferences : $portraitProgramPreferences,
      outputCanvas: activeProgramCanvasRole == .landscape ? outputCanvas : portraitOutputCanvas,
      landscapeCompositeProgramDefinition: $compositeProgramDefinition,
      landscapeProgramPreferences: $programPreferences,
      landscapeOutputCanvas: outputCanvas,
      portraitCompositeProgramDefinition: $portraitCompositeProgramDefinition,
      portraitProgramPreferences: $portraitProgramPreferences,
      portraitOutputCanvas: portraitOutputCanvas,
      landscapeVideoLayerPlacementPreview: landscapeVideoLayerPlacementPreview,
      portraitVideoLayerPlacementPreview: portraitVideoLayerPlacementPreview,
      previewLandscapeVideoLayerPlacement: { previewVideoLayerPlacement($0, role: .landscape) },
      previewPortraitVideoLayerPlacement: { previewVideoLayerPlacement($0, role: .portrait) },
      videoBitRate: activeProgramCanvasRole == .landscape
        ? landscapeVideoBitRate : portraitVideoBitRate,
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
      selectedLandscapeLiveStreamID: selectedLandscapeLiveStreamID,
      selectedPortraitLiveStreamID: selectedPortraitLiveStreamID,
      selectedProgramName: selectedProgramDefinitionName,
      windowState: windowState,
      isOutputSessionStartEnabled: isGlobalOutputSessionStartEnabled,
      outputSessionStartLabel: globalOutputSessionStartAccessibilityLabel,
      showsOutputSessionControls: windowState.mode == .output,
      existingBroadcasts: existingBroadcasts,
      existingLiveStreams: existingLiveStreams,
      isLoadingBroadcasts: isLoadingBroadcasts,
      featureAvailability: featureAvailability,
      refreshExistingBroadcasts: refreshExistingBroadcasts,
      streamKeyConfigurations: streamKeyConfigurations,
      saveStreamKeyConfigurations: saveStreamKeyConfigurations,
      importStreamKeyConfiguration: importStreamKeyConfiguration,
      refreshExistingLiveStreams: refreshExistingLiveStreams,
      manageYouTubeBroadcasts: manageYouTubeBroadcasts,
      chooseOutputDirectory: chooseOutputDirectory,
      applyOutputSettings: applyOutputSettings,
      selectBroadcast: selectBroadcast,
      selectLandscapeLiveStream: selectLandscapeLiveStream,
      selectPortraitLiveStream: selectPortraitLiveStream,
      captureFrame: captureFrame,
      openScreenshotsDirectory: openScreenshotsDirectory,
      verifyRecording: verifyRecording,
      startOutputSession: startOutputSession,
      pauseOutputSession: pauseOutputSession,
      stopOutputSession: stopOutputSession
    )
  }

  private var landscapeVideoLayerPlacementPreview: AnyView {
    AnyView(
      ProgramPreviewPane(
        outputCanvas: outputCanvas,
        previewSettings: $previewSettings,
        workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
        backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory,
        lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
        programRuntime: selectedProgramRuntime,
        selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
        compositeProgramDefinition: compositeProgramDefinition,
        workspaceInputDevices: workspaceInputDevices,
        workspaceAudioChannels: compositeProgramDefinition.audioChannels,
        inputCameraDeviceMappings: inputCameraDeviceMappings
      )
    )
  }

  private var portraitVideoLayerPlacementPreview: AnyView {
    AnyView(
      ProgramPreviewPane(
        outputCanvas: portraitOutputCanvas,
        previewSettings: $previewSettings,
        workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
        backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory,
        lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
        programRuntime: selectedPortraitProgramRuntime,
        selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
        compositeProgramDefinition: portraitCompositeProgramDefinition,
        workspaceInputDevices: workspaceInputDevices,
        workspaceAudioChannels: portraitCompositeProgramDefinition.audioChannels,
        inputCameraDeviceMappings: inputCameraDeviceMappings
      )
    )
  }

  private func previewVideoLayerPlacement(
    _ layer: VideoLayerPreference,
    role: ProgramCanvasRole
  ) {
    let programName = selectedProgramDefinitionName ?? "New Program"
    let preferences = role == .landscape ? programPreferences : portraitProgramPreferences
    var layers = preferences.videoLayers(forProgramNamed: programName)
    guard let index = layers.firstIndex(where: { $0.id == layer.id }) else { return }
    layers[index] = layer

    let canvas = role == .landscape ? outputCanvas : portraitOutputCanvas
    let composite =
      role == .landscape
      ? compositeProgramDefinition : portraitCompositeProgramDefinition
    let resolved = WorkspaceVideoComponentResolver.applying(
      videoComponents,
      layers: layers,
      to: composite,
      coordinateWidth: Float(canvas.canvasSize.width),
      coordinateHeight: Float(canvas.canvasSize.height)
    )
    let runtime = role == .landscape ? selectedProgramRuntime : selectedPortraitProgramRuntime
    runtime.updateDestinations(from: resolved)
  }

  private var portraitOutputCanvas: OutputCanvasModel {
    OutputCanvasModel(
      canvasSize: .init(width: 1_080, height: 1_920),
      programDefinitionFrameRate: 60
    )
  }

  public struct ToolbarAction {
    public let id: String
    public let title: String
    public let symbol: String
    public let enabled: Bool
    public let perform: () -> Void
  }

  public var managesPrograms: Bool { selectedSidebarItem == .programs }
  public var programSwitchStatus: String {
    if windowState.isProgramRuntimeTransitioning { return "Switching Program" }
    return switch windowState.outputSessionState {
    case .idle: "Stopped"
    case .starting, .pausing, .stopping: "Changing state"
    case .running: "Running"
    case .readyToRestart: "Paused"
    }
  }

  public var toolbarActions: [ToolbarAction] {
    if managesPrograms { return [] }
    var actions: [ToolbarAction] = [
      .init(
        id: "toolbarStopOutputSessionButton", title: "Stop Output", symbol: "stop.fill",
        enabled: canUseToolbarStop, perform: stopOutputSession),
      .init(
        id: "toolbarOutputSessionToggleButton",
        title: windowState.outputSessionState == .running
          ? "Pause Output" : globalOutputSessionStartAccessibilityLabel,
        symbol: windowState.outputSessionState == .running ? "pause.fill" : "play.fill",
        enabled: windowState.outputSessionState == .running
          ? !windowState.isOperationLocked : canUseToolbarStart,
        perform: windowState.outputSessionState == .running
          ? pauseOutputSession : startOutputSession),
      .init(
        id: "toolbarCaptureOutputFrameButton", title: "Capture Screenshot(s)", symbol: "camera",
        enabled: canCaptureOutputFrame, perform: captureFrame),
      .init(
        id: "toolbarCutRecordingButton", title: "Cut Recording", symbol: "scissors",
        enabled: canCutRecording, perform: cutRecording),
    ]
    if let target = selectedSidebarItem, canRename(target) {
      actions.append(
        .init(
          id: "renameWorkspaceResourceButton", title: "Rename…", symbol: "pencil",
          enabled: !windowState.isOperationLocked,
          perform: { requestWorkspaceResourceRename(target) }))
    }
    if case .some(.vision(let id)) = selectedSidebarItem,
      let vision = visions.first(where: { $0.id == id })
    {
      actions.append(
        .init(
          id: "toolbarAnalyzeVisionButton", title: "Analyze Current Frame", symbol: "sparkles",
          enabled: featureAvailability.supportsVision && !windowState.isOperationLocked
            && windowState.outputSessionState == .running
            && vision.updateIntervalSeconds == nil
            && !isVisionBusy(visionRuntimePresenter.status(forVisionID: vision.id)),
          perform: { analyzeVision(vision) }))
    }
    return actions
  }

  public var externalToolActions: [ToolbarAction] {
    [
      .init(
        id: "console", title: "Open Stream Console", symbol: "",
        enabled: canOpenYouTubeExternalTools, perform: openYouTubeStreamConsole),
      .init(
        id: "chat", title: "Open Live Chat", symbol: "", enabled: canOpenYouTubeExternalTools,
        perform: openYouTubeLiveChat),
      .init(
        id: "control", title: "Open Live Control Room", symbol: "",
        enabled: canOpenYouTubeExternalTools, perform: openYouTubeLiveControlRoom),
    ]
  }
  public var programNames: [String] { programRecords.map(\.name) }
  public var activeProgram: Binding<String?> { activeProgramSelection }
  public var programSwitchEnabled: Bool {
    windowState.mode == .edit || canChangeProgramDuringOutput
  }

  private var canUseToolbarStart: Bool {
    guard isGlobalOutputSessionStartEnabled else { return false }
    return windowState.outputSessionState == .idle
      || windowState.outputSessionState == .readyToRestart
  }

  private var canUseToolbarStop: Bool {
    return windowState.outputSessionState == .running
      || windowState.outputSessionState == .readyToRestart
  }

  private var canCaptureOutputFrame: Bool {
    windowState.outputSessionState == .running
      && windowState.activeOutputMode?.recordsLocally == true
      && !windowState.isRecordFinalizing
      && !windowState.isProgramRuntimeTransitioning
  }

  private var canCutRecording: Bool {
    windowState.outputSessionState == .running
      && windowState.activeOutputMode?.recordsLocally == true
      && !windowState.isRecordFinalizing
      && !windowState.isProgramRuntimeTransitioning
      && !windowState.isRecordCutCoolingDown
  }

  private var canOpenYouTubeExternalTools: Bool {
    guard featureAvailability.supportsYouTube,
      let selectedBroadcastID,
      existingBroadcasts.contains(where: { $0.id == selectedBroadcastID })
    else { return false }
    return outputDestination.streamsToYouTube
      || windowState.activeOutputMode?.streamsToYouTube == true
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

}

extension ErrorDialogKind {
  public var title: LocalizedStringResource {
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

  public var message: LocalizedStringResource {
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
    @State private var portraitCompositeProgramDefinition = CompositeProgramDefinition()
    @State private var programPreferences = LDTXAppUIPreviewFixtures.programPreferences
    @State private var portraitProgramPreferences = ProgramPreferences()
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
        portraitCompositeProgramDefinition: $portraitCompositeProgramDefinition,
        programPreferences: $programPreferences,
        portraitProgramPreferences: $portraitProgramPreferences,
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
        selectedPortraitProgramRuntime: previewRuntime,
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
        refreshCameras: {},
        deleteWorkspaceInputDevice: { _ in },
        stopOutputSession: {},
        startOutputSession: {},
        pauseOutputSession: {},
        addProgramDefinition: { _ in },
        renameProgramDefinition: { _, _ in true },
        deleteProgramDefinition: { _ in },
        moveProgramDefinition: { _, _ in },
        refreshExistingBroadcasts: {},
        manageYouTubeBroadcasts: {},
        analyzeVision: { _ in },
        captureFrame: {},
        openScreenshotsDirectory: {}
      )
    }
  }
#endif
