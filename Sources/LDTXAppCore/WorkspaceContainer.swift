// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AppKit
import Combine
import CoreImage
import Foundation
import LDTXAppUI
import LDTXCapture
import LDTXDash
import LDTXDiagnostics
import LDTXProgram
import LDTXProgramRendering
import LDTXProgramRuntime
import LDTXRecording
import LDTXTaskQueue
import LDTXWorkspace
import LDTXYouTube
import LDTXYouTubeRTMPS
import OSLog
import Observation
import SwiftUI
import UniformTypeIdentifiers

private let ldtxAppLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "App"
)

private let youtubeRTMPSLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "YouTubeRTMPS"
)

private enum WorkspaceLockOpenError: LocalizedError {
  case cancelled

  var errorDescription: String? {
    "Opening the locked Workspace was cancelled."
  }
}

private enum WorkspaceOutputFailureSource: String, Sendable {
  case outputSession = "Output session"
  case recording = "Recording service"
  case youtube = "YouTube service"
  case startup = "Output startup"
}

private struct WorkspaceOutputFailure: @unchecked Sendable {
  var source: WorkspaceOutputFailureSource
  var error: Error
  var operationID: UUID
  var outputMode: CaptureOutputMode
}

struct WorkspacePreferenceSnapshots {
  var programPreferences: ProgramPreferences
  var physicalDeviceIDsByInputDeviceID: [String: String]
  var inputCameraDeviceMappings: [String: String]
  var inputAudioDeviceMappings: [String: String]
  var inputAudioMonitorChannelKeys: Set<String>
  var selectedProgramName: String?
  var outputDestination: OutputDestination

  func apply(to preferences: inout WorkspacePreferences) {
    preferences.programPreferences = programPreferences
    preferences.physicalDeviceIDsByInputDeviceID = physicalDeviceIDsByInputDeviceID
    preferences.inputCameraDeviceMappings = inputCameraDeviceMappings
    preferences.inputAudioDeviceMappings = inputAudioDeviceMappings
    preferences.inputAudioMonitorChannelKeys = inputAudioMonitorChannelKeys
    preferences.selectedProgramName = selectedProgramName
    preferences.outputDestination = outputDestination
  }
}

extension UTType {
  static let ldtxWorkspace = UTType(exportedAs: "tokyo.kaito.ldtx.workspace")
}

@MainActor
private final class WorkspaceRuntimeState: ObservableObject {
  let windowID = UUID()
  let captureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  let audioCoordinator: WorkspaceAudioCoordinator
  let landscapeProgramPreferencesState: ProgramPreferencesState
  let portraitProgramPreferencesState: ProgramPreferencesState
  /// Program Runtimes are shared by the Editor and Output modes for the
  /// lifetime of this Workspace window.
  let programRuntimePool = WorkspaceProgramRuntimePool()

  init() {
    let captureSessionCoordinator = WorkspaceCaptureSessionCoordinator()
    self.captureSessionCoordinator = captureSessionCoordinator
    audioCoordinator = WorkspaceAudioCoordinator(
      captureSessionCoordinator: captureSessionCoordinator)
    landscapeProgramPreferencesState = ProgramPreferencesState()
    portraitProgramPreferencesState = ProgramPreferencesState()
  }
}

@MainActor
private final class WorkspaceProgramRuntimePool {
  private(set) var runtimesByKey: [String: ProgramRuntime] = [:]
  private var bootstrapRuntime: ProgramRuntime?

  private func key(name: String, role: ProgramCanvasRole) -> String {
    "\(name)\u{1f}\(role.rawValue)"
  }

  func runtime(named name: String?, role: ProgramCanvasRole) -> ProgramRuntime? {
    name.flatMap { runtimesByKey[key(name: $0, role: role)] }
  }

  func insert(_ runtime: ProgramRuntime, named name: String, role: ProgramCanvasRole) {
    runtimesByKey[key(name: name, role: role)] = runtime
  }

  func removeRuntime(named name: String) {
    for role in ProgramCanvasRole.allCases {
      runtimesByKey.removeValue(forKey: key(name: name, role: role))
    }
  }

  func bootstrapRuntime(using makeRuntime: () -> ProgramRuntime) -> ProgramRuntime {
    if let bootstrapRuntime { return bootstrapRuntime }
    let runtime = makeRuntime()
    bootstrapRuntime = runtime
    return runtime
  }

  func clear() {
    runtimesByKey.removeAll()
    bootstrapRuntime = nil
  }
}

@MainActor
@Observable
final class WorkspaceSession {
  var request: WorkspaceWindowRequest
  private let applicationRouter: LDTXApplicationRouter
  var oauthClientState: OAuthClientState
  var authState: YouTubeAuthState
  private let youtubeClientService: YouTubeClientService
  private let lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  private var runtimeState: WorkspaceRuntimeState
  private var windowMode: WorkspaceWindowState.Mode
  private var shutdownCoordinator: WorkspaceShutdownCoordinator
  private var windowCloseCoordinator = WorkspaceWindowCloseCoordinator()
  private var eventCoordinator: WorkspaceEventCoordinator
  private var outputCoordinator = WorkspaceOutputCoordinator()
  private var outputCanvas = OutputCanvasModel()
  /// Deliberately session-local. Persisting a broadcast ID can reconnect a
  /// later Workspace session to a stale or unintended live broadcast.
  private var transientSelectedYouTubeBroadcastID: String?
  /// Workspace-local assignments to configurations stored in Keychain.
  private var transientLandscapeLiveStreamID: String?
  private var transientPortraitLiveStreamID: String?
  private var previewSettings = AppPreviewSettings()
  private var applicationOutputPreferencesData: Data {
    get {
      UserDefaults.standard.data(forKey: "tokyo.kaito.ldtx.application-output-preferences.v1")
        ?? Data()
    }
    set {
      UserDefaults.standard.set(
        newValue, forKey: "tokyo.kaito.ldtx.application-output-preferences.v1")
    }
  }
  private var legacyApplicationOutputSettingsData: Data {
    get { UserDefaults.standard.data(forKey: "tokyo.kaito.ldtx.output-settings.v1") ?? Data() }
    set { UserDefaults.standard.set(newValue, forKey: "tokyo.kaito.ldtx.output-settings.v1") }
  }
  private var appPreviewSettingsData: Data {
    get { UserDefaults.standard.data(forKey: "tokyo.kaito.ldtx.preview-settings.v1") ?? Data() }
    set { UserDefaults.standard.set(newValue, forKey: "tokyo.kaito.ldtx.preview-settings.v1") }
  }
  private var existingBroadcasts: [YouTubeLiveBroadcast] = []
  private var existingLiveStreams: [LiveStreamSummary] = []
  private var streamKeyConfigurations: [YouTubeRTMPSStreamKeyConfiguration] = []
  private var streamKeyConfigurationsLoadFailed = false
  private var compositeProgramDefinition = CompositeProgramDefinition()
  private var portraitCompositeProgramDefinition = CompositeProgramDefinition()
  private var monitoredProgramCanvasRole: ProgramCanvasRole = .landscape
  private var sessionTaskQueue: SessionTaskQueue?
  private var recordingDockStatusID = UUID()
  private let screenCaptureService = ScreenCaptureService()
  private var workspaceResourceQueue: WorkspaceResourceQueue
  private var visionFeature: any WorkspaceVisionFeatureProviding
  private var dashStreamContinuityStore = YouTubeOutputWorkspaceStateStore()
  private var isLoadingBroadcasts = false
  private var isConnectingBroadcast = false
  private var captureDeviceStore = CaptureDeviceStore(service: DefaultCaptureDeviceService())
  private var localOutputStore = LocalOutputStore(
    service: DefaultLocalOutputService(fileManager: .default)
  )
  private var logStore = LogStore()
  private var programLibrary = ProgramLibrary(
    service: InMemoryProgramLibraryService()
  )
  private var selectedSidebarItem: WorkspaceSidebarItem? = .videoLayers
  private var selectedProgramDefinitionName: String?
  private var persistenceCoordinator = WorkspacePersistenceCoordinator()
  private var didInitializeWorkspace = false
  private var outputConfigurationRecoveryDescription: String?
  private var outputFailureDescription: String?
  private var visionRecordingFailureDescription: String?
  private var isProgramDefinitionDirty = false
  private var programAddErrorMessage: String?
  private var presentedErrorDialog: ErrorDialogKind?
  private var workspaceResourceRenameRequest: WorkspaceResourceRenameRequest?
  private var isRenamingWorkspaceResource = false
  private var captureFrameFeedback: OutputFrameCaptureFeedback?

  private var workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator {
    runtimeState.captureSessionCoordinator
  }

  private var audioCoordinator: WorkspaceAudioCoordinator { runtimeState.audioCoordinator }

  private var programInputDevices: [WorkspaceInputDeviceRecord] {
    get { persistenceCoordinator.runtimeInputDevices }
    set { persistenceCoordinator.runtimeInputDevices = newValue }
  }

  private var workspaceAudioChannels: [ProgramAudioChannel] {
    get { persistenceCoordinator.audioChannels }
    set { persistenceCoordinator.audioChannels = newValue }
  }

  private var visions: [WorkspaceVisionDefinition] {
    get { persistenceCoordinator.visions }
    set { persistenceCoordinator.visions = newValue }
  }

  private var workspaceVideoComponents: [WorkspaceVideoComponentRecord] {
    get { persistenceCoordinator.videoComponents }
    set { persistenceCoordinator.videoComponents = newValue }
  }

  private var workspaceVideoPTSMasterInputDeviceID: String? {
    get { persistenceCoordinator.videoPTSMasterInputDeviceID }
    set { persistenceCoordinator.videoPTSMasterInputDeviceID = newValue }
  }

  private var inputCameraDeviceMappings: [String: String] {
    get { persistenceCoordinator.inputCameraDeviceMappings }
    set { persistenceCoordinator.inputCameraDeviceMappings = newValue }
  }

  private var inputAudioDeviceMappings: [String: String] {
    get { persistenceCoordinator.inputAudioDeviceMappings }
    set { persistenceCoordinator.inputAudioDeviceMappings = newValue }
  }

  private var inputAudioPassthroughChannelKeys: Set<String> {
    get { persistenceCoordinator.inputAudioMonitorChannelKeys }
    set { persistenceCoordinator.inputAudioMonitorChannelKeys = newValue }
  }

  private var outputDestination: OutputDestination {
    get { persistenceCoordinator.outputDestination }
    set { persistenceCoordinator.outputDestination = newValue }
  }

  /// The Runtime for the Program selected in this Window. Editor previews and
  /// output sessions both consume the same Program-scoped Runtime.
  private var selectedProgramRuntime: ProgramRuntime {
    guard let record = selectedProgramDefinitionRecord else {
      return fallbackProgramRuntime
    }
    return programRuntime(for: record, role: .landscape)
  }

  private var selectedPortraitProgramRuntime: ProgramRuntime {
    guard let record = selectedProgramDefinitionRecord else {
      return fallbackProgramRuntime
    }
    return programRuntime(for: record, role: .portrait)
  }

  /// A bootstrap renderer is used only before a Workspace has selected a
  /// Program. It is never used for an Editor or Output Program.
  private var fallbackProgramRuntime: ProgramRuntime {
    runtimeState.programRuntimePool.bootstrapRuntime { makeProgramRuntime() }
  }

  private func makeProgramRuntime(role: ProgramCanvasRole = .landscape) -> ProgramRuntime {
    AppFeatureRegistry.provider.makeProgramRuntime(
      captureSessionCoordinator: workspaceCaptureSessionCoordinator,
      programPreferencesState:
        role == .landscape
        ? runtimeState.landscapeProgramPreferencesState
        : runtimeState.portraitProgramPreferencesState,
      lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry
    )
  }

  private func programRuntime(
    for record: SavedProgramDefinitionRecord,
    role: ProgramCanvasRole
  ) -> ProgramRuntime {
    if let runtime = runtimeState.programRuntimePool.runtime(named: record.name, role: role) {
      return runtime
    }
    let runtime = makeProgramRuntime(role: role)
    runtimeState.programRuntimePool.insert(runtime, named: record.name, role: role)
    return runtime
  }

  init(
    request: WorkspaceWindowRequest,
    applicationRouter: LDTXApplicationRouter,
    oauthClientState: OAuthClientState,
    authState: YouTubeAuthState,
    youtubeClientService: YouTubeClientService,
    lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  ) {
    let workspaceResourceQueue = WorkspaceResourceQueue(
      label: "tokyo.kaito.ldtx.workspace.delayed-resources"
    )
    self.request = request
    self.applicationRouter = applicationRouter
    self.oauthClientState = oauthClientState
    self.authState = authState
    self.youtubeClientService = youtubeClientService
    self.lowFrequencyUpdateRegistry = lowFrequencyUpdateRegistry
    shutdownCoordinator = WorkspaceShutdownCoordinator(
      logger: applicationRouter.makeEventTaskLogger(queueKind: .workspaceResources)
    )
    eventCoordinator = WorkspaceEventCoordinator(
      logger: applicationRouter.makeEventTaskLogger(queueKind: .workspaceEvents)
    )
    self.workspaceResourceQueue = workspaceResourceQueue
    visionFeature = AppFeatureRegistry.provider.makeVisionFeature(
      workspaceResourceQueue: workspaceResourceQueue)
    windowMode = .edit
    runtimeState = WorkspaceRuntimeState()
  }

  @ObservationIgnored var onClose: () -> Void = {}
  @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
  private var observationGeneration = 0
  @ObservationIgnored private var isStopping = false
  @ObservationIgnored private var isStopped = false
  @ObservationIgnored private var stopCompletions: [@MainActor @Sendable () -> Void] = []

  var actions: WorkspaceActions { workspaceActions }
  func confirmClose() -> Bool { windowCloseCoordinator.confirmClose() }
  func shutdown() async {
    await withCheckedContinuation { continuation in stopWorkspace { continuation.resume() } }
    RecordingDockStatusController.shared.setStatus(nil, for: recordingDockStatusID)
    WorkspaceCommandCoordinator.shared.unregister(workspaceID: runtimeState.windowID)
  }

  func attach(to window: NSWindow) {
    WorkspaceCommandCoordinator.shared.register(
      workspaceID: runtimeState.windowID, actions: workspaceActions)
    windowCloseCoordinator.beginInstalling(
      window: window, hasUnsavedChanges: hasUnsavedWorkspaceChanges,
      saveBeforeClose: { [weak self] in self?.saveWorkspaceBeforeClose() ?? false },
      onClose: { [weak self] completion in
        guard let self else {
          completion()
          return
        }
        self.stopWorkspace(completion: completion)
      },
      onBecomeKey: { [weak self] in
        guard let self else { return }
        WorkspaceCommandCoordinator.shared.activate(workspaceID: self.runtimeState.windowID)
      })
  }

  func start() {
    guard !didInitializeWorkspace else { return }
    performStartupTasks()
    guard !isStopping else { return }
    observeChanges()
    for publisher in [
      runtimeState.objectWillChange.eraseToAnyPublisher(),
      oauthClientState.objectWillChange.eraseToAnyPublisher(),
      authState.objectWillChange.eraseToAnyPublisher(),
    ] {
      publisher.sink { [weak self] _ in
        Task { @MainActor in self?.observationGeneration += 1 }
      }.store(in: &subscriptions)
    }
  }

  private func observe<Value: Equatable>(
    _ read: @escaping @MainActor (WorkspaceSession) -> Value,
    changed: @escaping @MainActor (WorkspaceSession) -> Void
  ) {
    guard !isStopping else { return }
    let previous = WorkspaceObservationValue(read(self))
    withObservationTracking {
      _ = read(self)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, !self.isStopping else { return }
        let current = read(self)
        self.observe(read, changed: changed)
        if previous.value != current { changed(self) }
      }
    }
  }

  private func observeChanges() {
    observe({ $0.selectedProgramDefinitionRecord }) { session in
      guard let record = session.selectedProgramDefinitionRecord else { return }
      session.compositeProgramDefinition = record.composite
      session.portraitCompositeProgramDefinition = record.portrait.composite
      session.applyWorkspaceVideoComponentsToSelectedProgram()
      session.isProgramDefinitionDirty = false
      session.updateWorkspaceWindowDirtyState()
    }
    observe({ $0.persistenceCoordinator.programPreferencesRevision }) {
      $0.distributeProgramPreferences()
    }
    observe({ $0.compositeProgramDefinition }) { $0.programDefinitionChanged() }
    observe({ $0.portraitCompositeProgramDefinition }) { $0.programDefinitionChanged() }
    observe({ $0.workspaceAudioChannels }) { $0.workspaceAudioChannelsChanged() }
    observe({ $0.outputCanvas.state }) { $0.outputCanvasChanged() }
    observe({ $0.inputAudioDeviceMappings }) { _ = $0.restartAudioMonitor() }
    observe({ $0.programInputDevices }) {
      $0.workspaceInputDevicesChanged()
      $0.validateSidebarSelection()
    }
    observe({ $0.persistenceCoordinator.store.isDirty }) { $0.updateWorkspaceWindowDirtyState() }
    observe({ $0.visions }) {
      $0.persistProgramLibraryAndOutputConfiguration()
      $0.synchronizeVisionAnalysis()
      $0.updateWorkspaceWindowDirtyState()
      $0.validateSidebarSelection()
    }
    observe({ $0.workspaceVideoComponents }) {
      $0.applyWorkspaceVideoComponentsToSelectedProgram()
      $0.persistProgramLibraryAndOutputConfiguration()
      $0.updateWorkspaceWindowDirtyState()
      $0.validateSidebarSelection()
    }
    observe({ $0.workspaceVideoPTSMasterInputDeviceID }) {
      $0.persistProgramLibraryAndOutputConfiguration()
      $0.updateSelectedProgramRuntime()
      $0.updateWorkspaceWindowDirtyState()
    }
  }

  private func validateSidebarSelection() {
    switch selectedSidebarItem {
    case .inputDevice(let id) where !programInputDevices.contains(where: { $0.id == id }):
      selectedSidebarItem = .output
    case .videoComponent(let id) where !workspaceVideoComponents.contains(where: { $0.id == id }):
      selectedSidebarItem = .output
    case .vision(let id) where !visions.contains(where: { $0.id == id }):
      selectedSidebarItem = .output
    default: break
    }
  }

  @ViewBuilder
  func pane(_ pane: WorkspacePane) -> some View {
    if pane == .content {
      workspaceView.pane(pane)
        .sheet(item: binding(\.workspaceResourceRenameRequest)) { [self] request in
          WorkspaceResourceRenameSheet(
            request: request, rename: performWorkspaceResourceRename,
            cancel: { [self] in workspaceResourceRenameRequest = nil })
        }
    } else {
      workspaceView.pane(pane)
    }
  }

  struct WindowAlert {
    let title: String
    let message: String
    let dismiss: () -> Void
  }
  var pendingAlert: WindowAlert? {
    if let message = outputConfigurationRecoveryDescription {
      return WindowAlert(
        title: "Output Configuration Reset", message: message,
        dismiss: { [weak self] in self?.outputConfigurationRecoveryDescription = nil })
    }
    if let message = outputFailureDescription {
      return WindowAlert(
        title: "Output Failed", message: message,
        dismiss: { [weak self] in self?.outputFailureDescription = nil })
    }
    if let message = visionRecordingFailureDescription {
      return WindowAlert(
        title: "Vision Recording Failed", message: message,
        dismiss: { [weak self] in self?.visionRecordingFailureDescription = nil })
    }
    if let message = programAddErrorMessage {
      return WindowAlert(
        title: "Program Could Not Be Added", message: message,
        dismiss: { [weak self] in self?.programAddErrorMessage = nil })
    }
    if let dialog = presentedErrorDialog {
      return WindowAlert(
        title: String(localized: dialog.title), message: String(localized: dialog.message),
        dismiss: { [weak self] in self?.presentedErrorDialog = nil })
    }
    return nil
  }

  private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<WorkspaceSession, Value>)
    -> Binding<Value>
  {
    Binding(
      get: { [self] in self[keyPath: keyPath] },
      set: { [self] in
        self[keyPath: keyPath] = $0
        if keyPath == \WorkspaceSession.compositeProgramDefinition
          || keyPath == \WorkspaceSession.portraitCompositeProgramDefinition
        {
          markProgramDefinitionDirty()
        }
      })
  }

  var workspaceView: LDTXAppUI.WorkspaceView {

    _ = observationGeneration
    return LDTXAppUI.WorkspaceView(
      activeProgramCanvasRole: Binding(
        get: { [self] in monitoredProgramCanvasRole },
        set: { [self] role in
          monitoredProgramCanvasRole = role
          restartAudioMonitor()
        }),
      selectedSidebarItem: binding(\.selectedSidebarItem),
      selectedProgramDefinitionName: activeProgramSelectionBinding,
      workspaceInputDevices: programInputDevicesBinding,
      workspaceAudioChannels: workspaceAudioChannelsBinding,
      visions: visionsBinding,
      videoComponents: workspaceVideoComponentsBinding,
      videoPTSMasterInputDeviceID: videoPTSMasterInputDeviceBinding,
      compositeProgramDefinition: binding(\.compositeProgramDefinition),
      portraitCompositeProgramDefinition: binding(\.portraitCompositeProgramDefinition),
      programPreferences: programPreferencesBinding,
      portraitProgramPreferences: portraitProgramPreferencesBinding,
      captureFrameFeedback: binding(\.captureFrameFeedback),
      requestWorkspaceResourceRename: requestWorkspaceResourceRename,
      isWorkspaceResourceRenameInProgress: isRenamingWorkspaceResource,
      windowState: WorkspaceWindowState(
        mode: windowMode,
        outputSessionState: outputSessionControlState,
        activeOutputMode: outputCoordinator.activeMode,
        isRecordFinalizing: outputCoordinator.isRecordFinalizing,
        isRecordCutCoolingDown: outputCoordinator.isRecordCutCoolingDown,
        isProgramRuntimeTransitioning: outputCoordinator.isProgramRuntimeTransitioning,
        isOperationLocked: eventCoordinator.isLocked
      ),
      outputCanvas: outputCanvas,
      landscapeVideoBitRate:
        persistenceCoordinator.store.definition.outputConfiguration.videoBitRate,
      portraitVideoBitRate:
        persistenceCoordinator.store.definition.outputConfiguration.portraitVideoBitRate,
      outputDestination: outputDestination,
      previewSettings: binding(\.previewSettings),
      visionRuntimePresenter: visionFeature.presenter,
      backgroundRemovalPreprocessorFactory: AppFeatureRegistry.provider
        .backgroundRemovalPreprocessorFactory,
      workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
      lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
      selectedProgramRuntime: selectedProgramRuntime,
      selectedPortraitProgramRuntime: selectedPortraitProgramRuntime,
      selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
      programRecords: programLibrary.records,
      activeProgramSelection: activeProgramSelectionBinding,
      inputCameraDeviceMappings: inputCameraDeviceMappings,
      audioPeakMeter: audioCoordinator.peakMeter,
      inputAudioPassthroughChannelKeys: inputAudioPassthroughChannelKeysBinding,
      cameras: captureDeviceStore.cameras.map { InputPhysicalDeviceOption(camera: $0) },
      audioDevices: captureDeviceStore.audioDevices.map {
        InputPhysicalDeviceOption(audioDevice: $0)
      },
      existingBroadcasts: existingBroadcastSummaries,
      existingLiveStreams: existingLiveStreams,
      isLoadingBroadcasts: isLoadingBroadcasts,
      isGlobalOutputSessionStartEnabled: isGlobalOutputSessionStartEnabled,
      globalOutputSessionStartAccessibilityLabel: globalOutputSessionStartAccessibilityLabel,
      refreshCameras: refreshCameras,
      deleteWorkspaceInputDevice: deleteWorkspaceInputDevice(id:),
      deleteWorkspaceVideoComponent: deleteWorkspaceVideoComponent(id:),
      deleteWorkspaceVision: deleteWorkspaceVision(id:),
      stopOutputSession: stopOutputSession,
      startOutputSession: windowMode == .output
        ? startLoadedOutputSession
        : { _ = self.startOutputSession() },
      pauseOutputSession: pauseOutputSession,
      addProgramDefinition: addProgramDefinition(named:),
      renameProgramDefinition: renameProgramDefinition(oldName:to:),
      deleteProgramDefinition: deleteProgramDefinition(named:),
      moveProgramDefinition: moveProgramDefinition(named:by:),
      refreshExistingBroadcasts: refreshExistingBroadcasts,
      streamKeyConfigurations: streamKeyConfigurations,
      saveStreamKeyConfigurations: saveStreamKeyConfigurations,
      importStreamKeyConfiguration: importStreamKeyConfiguration,
      refreshExistingLiveStreams: refreshExistingLiveStreams,
      manageYouTubeBroadcasts: manageYouTubeBroadcasts,
      chooseOutputDirectory: chooseLocalOutputDirectory,
      applyOutputSettings: applyOutputDestination,
      selectedBroadcastID: transientSelectedYouTubeBroadcastID,
      selectBroadcast: { self.transientSelectedYouTubeBroadcastID = $0 },
      selectedLandscapeLiveStreamID: transientLandscapeLiveStreamID,
      selectedPortraitLiveStreamID: transientPortraitLiveStreamID,
      selectLandscapeLiveStream: { self.transientLandscapeLiveStreamID = $0 },
      selectPortraitLiveStream: { self.transientPortraitLiveStreamID = $0 },
      analyzeVision: analyzeVision,
      captureFrame: captureOutputFrame,
      cutRecording: cutSessionRecord,
      openYouTubeStreamConsole: openYouTubeStreamConsole,
      openYouTubeLiveChat: openYouTubeLiveChat,
      openYouTubeLiveControlRoom: openYouTubeLiveControlRoom,
      openScreenshotsDirectory: openScreenshotsDirectory,
      verifyRecording: verifyRecordingShield,
      featureAvailability: workspaceFeatureAvailability
    )
  }

  private var workspaceFeatureAvailability: WorkspaceFeatureAvailability {
    AppFeatureRegistry.provider.workspaceFeatureAvailability
  }

  private func captureOutputFrame() {
    guard !outputCoordinator.isProgramRuntimeTransitioning else {
      captureFrameFeedback = OutputFrameCaptureFeedback(
        message: "Wait for the Program switch to complete before capturing Screenshot(s).",
        isError: true)
      return
    }
    guard let recordLease = outputCoordinator.beginRecordAuxiliaryOperation() else {
      captureFrameFeedback = OutputFrameCaptureFeedback(
        message: "Start recording before capturing Screenshot(s).",
        isError: true)
      return
    }
    var releasesRecordLeaseOnReturn = true
    defer {
      if releasesRecordLeaseOnReturn {
        outputCoordinator.endRecordAuxiliaryOperation(recordLease)
      }
    }
    let recordingPackageDirectory = recordLease.packageDirectory

    let capturedAt = screenCaptureService.captureDate()
    var sources: [ScreenCaptureSource] = []
    var unavailableSourceNames: [String] = []

    do {
      if let pixelBuffer = selectedProgramRuntime.latestFrame()?.pixelBuffer {
        sources.append(
          try screenCaptureService.snapshot(
            pixelBuffer: pixelBuffer,
            name: "Landscape Program"))
      } else {
        unavailableSourceNames.append("Landscape Program")
      }
      if let pixelBuffer = selectedPortraitProgramRuntime.latestFrame()?.pixelBuffer {
        sources.append(
          try screenCaptureService.snapshot(
            pixelBuffer: pixelBuffer,
            name: "Portrait Program"))
      } else {
        unavailableSourceNames.append("Portrait Program")
      }

      for inputDevice in programInputDevices where inputDevice.kind == .video {
        guard let physicalDeviceID = inputDevice.physicalDeviceID,
          let pixelBuffer = workspaceCaptureSessionCoordinator.latestPixelBuffer(
            forCameraID: physicalDeviceID)
        else {
          unavailableSourceNames.append(inputDevice.name)
          continue
        }
        sources.append(
          try screenCaptureService.snapshot(
            pixelBuffer: pixelBuffer,
            name: "Input-\(inputDevice.name)"))
      }
    } catch {
      captureFrameFeedback = OutputFrameCaptureFeedback(
        message: error.localizedDescription,
        isError: true)
      appendLog("Output frame snapshot failed: \(error.localizedDescription)")
      return
    }

    guard !sources.isEmpty else {
      captureFrameFeedback = OutputFrameCaptureFeedback(
        message: "No Program or Video Input Device frames are available yet.",
        isError: true)
      return
    }

    let capturedSources = sources
    let captureService = screenCaptureService
    let skippedDescription =
      unavailableSourceNames.isEmpty
      ? ""
      : "; unavailable: \(unavailableSourceNames.joined(separator: ", "))"
    let submissionID = UUID()
    guard let sessionTaskQueue else {
      captureFrameFeedback = OutputFrameCaptureFeedback(
        message: "The Screenshot could not be queued outside an Output Session.",
        isError: true)
      return
    }
    let submitted = sessionTaskQueue.submit(
      key: SessionTaskKey("screenshot:\(submissionID.uuidString)"),
      source: .normal
    ) { finish in
      { stopToken, _ in
        defer {
          Task { @MainActor in
            self.outputCoordinator.endRecordAuxiliaryOperation(recordLease)
          }
          finish()
        }
        guard !stopToken.isStopRequested else { return }

        do {
          let result = try captureService.captureSet(
            sources: capturedSources,
            capturedAt: capturedAt,
            recordingPackageDirectory: recordingPackageDirectory)
          Task { @MainActor in
            self.captureFrameFeedback = OutputFrameCaptureFeedback(
              message:
                "Saved \(result.capturedAt.formatted(date: .omitted, time: .standard)) Screenshot(s)\(skippedDescription)",
              isError: false)
            self.appendLog(
              "Captured \(result.outputURLs.count) output frames: \(result.directory.path)")
          }
        } catch {
          let description = error.localizedDescription
          Task { @MainActor in
            self.captureFrameFeedback = OutputFrameCaptureFeedback(
              message: description,
              isError: true)
            self.appendLog("Output frame capture failed: \(description)")
          }
        }
      }
    }
    guard submitted else {
      captureFrameFeedback = OutputFrameCaptureFeedback(
        message: "The Screenshot could not be queued.",
        isError: true)
      appendLog("Output frame capture submission was rejected")
      return
    }
    releasesRecordLeaseOnReturn = false
  }

  private func cutSessionRecord() {
    let accepted = eventCoordinator.enqueue { _ in
      guard self.outputCoordinator.requestRecordCut() else {
        self.appendLog("Cut request was rejected.")
        return
      }
      // Bound the time to the next Cut boundary without changing the
      // keyframe-only record contract.
      self.outputCoordinator.currentSession?.requestVideoKeyFrame()
    }
    guard accepted else {
      appendLog("Cut request was rejected.")
      return
    }
  }

  private func openScreenshotsDirectory() {
    guard let recordingPackageDirectory = activeRecordingPackageDirectory else { return }
    do {
      let directory = try screenCaptureService.prepareScreenshotsDirectory(
        in: recordingPackageDirectory)
      NSWorkspace.shared.open(directory)
    } catch {
      captureFrameFeedback = OutputFrameCaptureFeedback(
        message: error.localizedDescription,
        isError: true)
      appendLog("Opening Screenshots directory failed: \(error.localizedDescription)")
    }
  }

  private func verifyRecordingShield() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = false
    panel.allowedContentTypes = [
      UTType(filenameExtension: RecordingPackage.pathExtension) ?? .directory
    ]
    panel.message = "Choose a completed LDTX recording package to verify."
    panel.prompt = "Verify"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let didAccess = url.startAccessingSecurityScopedResource()
    Task {
      defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
      let result = await Task.detached {
        RecordingShieldVerifier().verify(packageAt: url)
      }.value
      presentRecordingShieldVerification(result, packageURL: url)
    }
  }

  private func presentRecordingShieldVerification(
    _ result: RecordingShieldVerificationResult,
    packageURL: URL
  ) {
    let message: String
    switch result.status {
    case .valid:
      message = "Recording Shield is valid."
    case .invalid:
      let details = result.issues.prefix(3).map { issue in
        [issue.kind.rawValue, issue.path].compactMap { $0 }.joined(separator: ": ")
      }.joined(separator: ", ")
      message = "Recording Shield is invalid: \(details)"
    case .unverifiable:
      message = "Recording Shield is unverifiable: \(result.reason?.rawValue ?? "unknown")"
    }
    captureFrameFeedback = OutputFrameCaptureFeedback(
      message: message, isError: result.status != .valid)
    appendLog(
      "Recording Shield verification: \(result.status.rawValue), package=\(packageURL.lastPathComponent)"
    )
  }

  private var activeRecordingPackageDirectory: URL? {
    guard isRecording else { return nil }
    return outputCoordinator.recordService?.packageDirectory
  }

  private func performStartupTasks() {
    guard !didInitializeWorkspace else { return }
    didInitializeWorkspace = true
    migrateLegacyApplicationOutputPreferencesIfNeeded()
    restoreAppPreviewSettings()
    if !LDTXRuntimeMode.isUITesting && !LDTXRuntimeMode.isUnitTesting {
      do { streamKeyConfigurations = try YouTubeStreamKeyConfigurationStore().load() } catch {
        streamKeyConfigurationsLoadFailed = true
        appendLog("Stream key configurations could not be loaded from Keychain.")
      }
    }
    if LDTXRuntimeMode.isUITesting || LDTXRuntimeMode.isUnitTesting {
      loadUITestingWorkspace()
    } else {
      switch request.source {
      case .new:
        initializeNewWorkspace()
      case .file(let workspaceURL):
        guard
          loadWorkspace(
            at: workspaceURL,
            clearsDetailSelectionAfterLoad: false
          )
        else {
          onClose()
          return
        }
      }
    }
    updateWorkspaceWindowDirtyState()
    refreshSavedProgramDefinitions()
    refreshCameras()
    updateSelectedProgramRuntime()
    restartAudioMonitor()
  }

  private func initializeNewWorkspace() {
    do {
      let store = try WorkspaceStore(clean: WorkspaceDefinition())
      try replaceWorkspaceStore(store, url: nil, clearsDetailSelection: false)
      appendLog("Created an unsaved Workspace.")
    } catch {
      appendLog("Workspace could not be initialized: \(error.localizedDescription)")
    }
  }

  private func stopWorkspace(completion: @escaping @MainActor @Sendable () -> Void = {}) {
    if isStopped {
      completion()
      return
    }
    stopCompletions.append(completion)
    guard !isStopping else { return }
    isStopping = true
    subscriptions.removeAll()
    persistPreviewSettings()
    runtimeState.programRuntimePool.clear()
    visionFeature.stop { [self] in
      stopWorkspaceResources { [self] in
        isStopped = true
        RecordingDockStatusController.shared.setStatus(nil, for: recordingDockStatusID)
        WorkspaceCommandCoordinator.shared.unregister(workspaceID: runtimeState.windowID)
        let completions = stopCompletions
        stopCompletions.removeAll()
        completions.forEach { $0() }
      }
    }
  }

  private func createSessionTaskQueue() {
    let outputCoordinator = outputCoordinator
    sessionTaskQueue = SessionTaskQueue(
      label: "tokyo.kaito.ldtx.workspace.session-data",
      logger: applicationRouter.makeEventTaskLogger(queueKind: .sessionTasks),
      finalizer: { completion in
        { _, logger in
          Task { @MainActor in
            _ = await outputCoordinator.stopRecordService()
            await logger.append(.sessionTasksFinalized)
            completion()
          }
        }
      })
  }

  private func finishSessionTasks() async {
    await stopVisionTasks()
    guard let sessionTaskQueue else { return }
    await withCheckedContinuation { continuation in
      sessionTaskQueue.finish {
        continuation.resume()
      }
    }
    if self.sessionTaskQueue === sessionTaskQueue {
      self.sessionTaskQueue = nil
    }
  }

  private func stopSessionTasks() async {
    await stopVisionTasks()
    guard let sessionTaskQueue else { return }
    await withCheckedContinuation { continuation in
      sessionTaskQueue.stop {
        continuation.resume()
      }
    }
    if self.sessionTaskQueue === sessionTaskQueue {
      self.sessionTaskQueue = nil
    }
  }

  private func stopWorkspaceResources(completion: @escaping @MainActor @Sendable () -> Void) {
    let audioCoordinator = audioCoordinator
    let captureCoordinator = workspaceCaptureSessionCoordinator

    let didBegin = shutdownCoordinator.beginShutdown(
      {
        await self.persistenceCoordinator.stopAutomaticSave()
        await self.eventCoordinator.interrupt()
        let (operationID, session, outputMode) = await MainActor.run {
          (
            self.outputCoordinator.invalidateOperations(for: .stopping),
            self.outputCoordinator.currentSession,
            self.outputCoordinator.activeMode ?? self.outputDestination.enabledCaptureOutputMode
              ?? .record
          )
        }
        if let session { await self.stopAndWait(for: session) }
        await self.finishSessionTasks()
        let serviceStopResult = await self.outputCoordinator.stopServices()
        await self.outputCoordinator.finishYouTubeOutputServiceProcess()
        await audioCoordinator.stopAndReset()
        await withCheckedContinuation { continuation in
          captureCoordinator.stopAndReset { continuation.resume() }
        }
        await self.workspaceResourceQueue.drainAndCleanup()
        await MainActor.run {
          if case .failure(let error) = serviceStopResult {
            self.logOutputServiceStopFailure(error, context: "workspace shutdown")
          }
          guard self.outputCoordinator.operationID == operationID else { return }
          if outputMode.recordsLocally {
            self.localOutputStore.endAccess()
          }
          self.outputCoordinator.resetSession()
          self.outputCoordinator.lifecycleState = .idle
        }
      },
      verifyStopped: {
        let audioStopped = audioCoordinator.isFullyStopped()
        let captureStopped = captureCoordinator.isFullyStopped()
        let outputStopped = await MainActor.run { self.outputCoordinator.isFullyStopped() }
        return audioStopped && captureStopped && outputStopped
      },
      completion: {
        self.persistenceCoordinator.releaseActiveLock()
        completion()
      }
    )
    if !didBegin, shutdownCoordinator.resourcesAreFullyStopped() {
      completion()
    }
  }

  private func replaceProgramPreferences(with preferences: ProgramPreferences) {
    persistenceCoordinator.replaceProgramPreferences(with: preferences)
  }

  private func distributeProgramPreferences() {
    let current = programPreferences
    selectedProgramRuntime.updateProgramPreferences(current)
    outputCoordinator.currentSession?.updateProgramPreferences(current)
    persistWorkspacePreferences()
    updateAudioMixGains()
  }

  private var programPreferences: ProgramPreferences {
    persistenceCoordinator.programPreferences
  }

  private var programPreferencesBinding: Binding<ProgramPreferences> {
    Binding(
      get: { self.programPreferences },
      set: { self.replaceProgramPreferences(with: $0) }
    )
  }

  private var portraitProgramPreferencesBinding: Binding<ProgramPreferences> {
    Binding(
      get: { self.persistenceCoordinator.portraitProgramPreferences },
      set: { preferences in
        guard self.persistenceCoordinator.portraitProgramPreferences != preferences else { return }
        self.persistenceCoordinator.replacePortraitProgramPreferences(with: preferences)
        self.updateMasterMeterGains()
        self.selectedPortraitProgramRuntime.updateProgramPreferences(preferences)
        self.outputCoordinator.currentSession?.updatePortraitProgramPreferences(preferences)
        self.persistWorkspacePreferences()
      }
    )
  }

  private func programDefinitionChanged() {
    updateAudioMixGains()
    updateSelectedProgramRuntime()
    restartAudioMonitor()
  }

  private func outputCanvasChanged() {
    persistProgramLibraryAndOutputConfiguration()
    updateSelectedProgramRuntime()
    synchronizeInputDeviceCaptures()
    updateWorkspaceWindowDirtyState()
  }

  private func workspaceAudioChannelsChanged() {
    persistProgramLibraryAndOutputConfiguration()
    updateAudioMixGains()
    updateSelectedProgramRuntime()
    restartAudioMonitor()
    updateWorkspaceWindowDirtyState()
  }

  private func markProgramDefinitionDirty() {
    isProgramDefinitionDirty = true
    updateWorkspaceWindowDirtyState()
  }

  private var workspaceActions: WorkspaceActions {
    WorkspaceActions(
      saveWorkspace: saveWorkspace,
      saveWorkspaceAs: { _ = self.saveWorkspaceAs() },
      reloadWorkspace: reloadWorkspace,
      canReloadWorkspace: persistenceCoordinator.url != nil
        && outputSessionControlState == .idle
    )
  }

  private var activeProgramSelectionBinding: Binding<String?> {
    Binding(
      get: { self.selectedProgramDefinitionName },
      set: { selectedName in
        self.selectProgramDefinition(named: selectedName, clearsDetailSelection: false)
      }
    )
  }

  private var inputAudioPassthroughChannelKeysBinding: Binding<Set<String>> {
    Binding(
      get: { self.inputAudioPassthroughChannelKeys },
      set: { channelKeys in
        guard self.inputAudioPassthroughChannelKeys != channelKeys else { return }
        self.inputAudioPassthroughChannelKeys = channelKeys
        self.persistWorkspacePreferences()
        self.updateAudioMixGains()
      }
    )
  }

  /// PTS selection is part of the rendering pipeline contract. It is frozen
  /// before Output mode builds the Program Runtime pool.
  private var videoPTSMasterInputDeviceBinding: Binding<String?> {
    Binding(
      get: { self.workspaceVideoPTSMasterInputDeviceID },
      set: { masterInputDeviceID in
        guard self.windowMode == .edit, !self.eventCoordinator.isLocked else { return }
        self.workspaceVideoPTSMasterInputDeviceID = masterInputDeviceID
      }
    )
  }

  private var hasUnsavedWorkspaceChanges: Bool {
    persistenceCoordinator.store.isDirty || isProgramDefinitionDirty
  }

  private var programInputDevicesBinding: Binding<[WorkspaceInputDeviceRecord]> {
    Binding(
      get: { self.programInputDevices },
      set: { newValue in
        if let (oldName, newName) = self.inputDeviceRename(
          from: self.programInputDevices, to: newValue)
        {
          self.performInputDeviceRename(from: oldName, to: newName)
          return
        }
        self.programInputDevices = newValue
        self.persistProgramLibraryAndOutputConfiguration()
        self.persistWorkspacePreferences()
        self.synchronizeInputDeviceCaptures()
        self.restartAudioMonitor()
      }
    )
  }

  private var workspaceAudioChannelsBinding: Binding<[ProgramAudioChannel]> {
    Binding(
      get: { self.workspaceAudioChannels },
      set: { self.workspaceAudioChannels = $0 }
    )
  }

  private var visionsBinding: Binding<[WorkspaceVisionDefinition]> {
    Binding(
      get: { self.visions },
      set: { newValue in
        if let (oldName, newName) = self.visionRename(from: self.visions, to: newValue) {
          self.performVisionRename(from: oldName, to: newName)
        } else {
          self.visions = newValue
        }
      }
    )
  }

  private var workspaceVideoComponentsBinding: Binding<[WorkspaceVideoComponentRecord]> {
    Binding(
      get: { self.workspaceVideoComponents },
      set: { self.workspaceVideoComponents = $0 }
    )
  }

  private func inputDeviceRename(
    from oldValues: [WorkspaceInputDeviceRecord],
    to newValues: [WorkspaceInputDeviceRecord]
  ) -> (String, String)? {
    guard oldValues.count == newValues.count else { return nil }
    let changed = oldValues.indices.filter { oldValues[$0].name != newValues[$0].name }
    guard changed.count == 1, let index = changed.first else { return nil }
    var normalized = newValues[index]
    normalized.name = oldValues[index].name
    guard normalized == oldValues[index] else { return nil }
    return (oldValues[index].name, newValues[index].name)
  }

  private func visionRename(
    from oldValues: [WorkspaceVisionDefinition],
    to newValues: [WorkspaceVisionDefinition]
  ) -> (String, String)? {
    guard oldValues.count == newValues.count else { return nil }
    let changed = oldValues.indices.filter { oldValues[$0].name != newValues[$0].name }
    guard changed.count == 1, let index = changed.first else { return nil }
    var normalized = newValues[index]
    normalized.name = oldValues[index].name
    guard normalized == oldValues[index] else { return nil }
    return (oldValues[index].name, newValues[index].name)
  }

  private func performInputDeviceRename(
    from oldName: String,
    to newName: String
  ) {
    guard let workspaceURL = ensureWorkspaceSavedForRename() else { return }
    let initialSidebarItem =
      selectedSidebarItem == .inputDevice(oldName)
      ? WorkspaceSidebarItem.inputDevice(newName) : selectedSidebarItem
    isRenamingWorkspaceResource = true
    defer { isRenamingWorkspaceResource = false }
    guard
      replaceWorkspaceForRename(
        at: workspaceURL,
        initialSidebarItem: initialSidebarItem,
        mutation: { definition, preferences in
          try definition.renameInputDevice(from: oldName, to: newName, preferences: &preferences)
        })
    else { return }
  }

  private func performVisionRename(from oldName: String, to newName: String) {
    guard let workspaceURL = ensureWorkspaceSavedForRename() else { return }
    let initialSidebarItem =
      selectedSidebarItem == .vision(oldName)
      ? WorkspaceSidebarItem.vision(newName) : selectedSidebarItem
    isRenamingWorkspaceResource = true
    defer { isRenamingWorkspaceResource = false }
    guard
      replaceWorkspaceForRename(
        at: workspaceURL,
        initialSidebarItem: initialSidebarItem,
        mutation: { definition, _ in
          try definition.renameVision(from: oldName, to: newName)
        })
    else { return }
  }

  private func requestWorkspaceResourceRename(_ item: WorkspaceSidebarItem) {
    guard windowMode == .edit, !isRenamingWorkspaceResource else { return }
    workspaceResourceRenameRequest = WorkspaceResourceRenameRequest(item: item)
  }

  private func performWorkspaceResourceRename(to proposedName: String) {
    guard let request = workspaceResourceRenameRequest, windowMode == .edit else { return }
    let newName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !newName.isEmpty, newName != request.name else {
      workspaceResourceRenameRequest = nil
      return
    }
    // Rename rewrites references across the Workspace. Commit the current
    // Program first, then replace the complete Definition and Preferences
    // together before saving and reopening the Workspace.
    guard let workspaceURL = ensureWorkspaceSavedForRename() else { return }
    isRenamingWorkspaceResource = true
    defer { isRenamingWorkspaceResource = false }
    let initialSidebarItem =
      selectedSidebarItem == request.sidebarItem
      ? request.renamedSidebarItem(newName) : selectedSidebarItem

    guard
      replaceWorkspaceForRename(
        at: workspaceURL,
        initialSidebarItem: initialSidebarItem,
        mutation: { definition, preferences in
          switch request.kind {
          case .inputDevice:
            try definition.renameInputDevice(
              from: request.name, to: newName, preferences: &preferences)
          case .videoComponent:
            try definition.renameVideoComponent(
              from: request.name, to: newName, preferences: &preferences)
          case .vision:
            try definition.renameVision(from: request.name, to: newName)
          }
        })
    else { return }
    workspaceResourceRenameRequest = nil
  }

  /// Applies a Workspace-wide rename to a complete persisted snapshot. The
  /// UI and runtime are not mutated until the complete Definition and
  /// Preferences have been written successfully, then reloaded as a unit.
  @discardableResult
  private func replaceWorkspaceForRename(
    at workspaceURL: URL,
    initialSidebarItem: WorkspaceSidebarItem?,
    mutation: (inout WorkspaceDefinition, inout WorkspacePreferences) throws -> Void
  ) -> Bool {
    let store = persistenceCoordinator.store
    let originalDefinition = store.definition
    let originalPreferences = store.preferences

    do {
      var definition = originalDefinition
      var preferences = originalPreferences
      try mutation(&definition, &preferences)
      store.replace(with: WorkspaceSnapshot(definition: definition, preferences: preferences))
      try persistenceCoordinator.save(store, to: workspaceURL)
      persistenceCoordinator.replace(store: store, url: workspaceURL)
      persistenceCoordinator.noteRecentDocument(workspaceURL)
      updateWorkspaceWindowDirtyState()
      guard
        reloadWorkspaceAfterRename(
          at: workspaceURL,
          initialSidebarItem: initialSidebarItem
        )
      else { return false }
      return true
    } catch {
      store.replace(
        with: WorkspaceSnapshot(
          definition: originalDefinition,
          preferences: originalPreferences
        )
      )
      appendLog("Workspace could not be renamed: \(error.localizedDescription)")
      return false
    }
  }

  private func loadUITestingWorkspace() {
    do {
      let packageURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("LDTXUITests", isDirectory: true)
        .appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString)
        .appendingPathExtension(WorkspacePackageLayout.pathExtension)
      let store = try WorkspaceStore(clean: WorkspaceDefinition(name: "UITest"))
      let lock = try acquireWorkspaceLock(at: packageURL, createsPackageDirectory: true)
      var didActivateLock = false
      defer {
        if !didActivateLock { persistenceCoordinator.releaseLock(lock) }
      }
      try replaceWorkspaceStore(store, url: packageURL, clearsDetailSelection: false)
      persistenceCoordinator.activateLock(lock)
      didActivateLock = true
      appendLog("Loaded UI testing Workspace: \(packageURL.path)")
    } catch {
      appendLog("UI testing Workspace could not be loaded: \(error.localizedDescription)")
    }
  }

  @discardableResult
  private func loadWorkspace(
    at url: URL,
    clearsDetailSelectionAfterLoad: Bool = true
  ) -> Bool {
    do {
      let lock = try acquireWorkspaceLock(at: url)
      var didActivateLock = false
      defer {
        if !didActivateLock { persistenceCoordinator.releaseLock(lock) }
      }
      let store = try persistenceCoordinator.load(at: url)
      try replaceWorkspaceStore(
        store,
        url: url,
        clearsDetailSelection: clearsDetailSelectionAfterLoad
      )
      persistenceCoordinator.activateLock(lock)
      didActivateLock = true
      persistenceCoordinator.noteRecentDocument(url)
      appendLog("Opened Workspace: \(url.path)")
      return true
    } catch {
      appendLog("Workspace could not be opened: \(error.localizedDescription)")
      return false
    }
  }

  private func saveWorkspace() {
    guard let workspaceURL = persistenceCoordinator.url else {
      saveWorkspaceAs()
      return
    }
    saveWorkspace(to: workspaceURL)
  }

  private func saveWorkspaceBeforeClose() -> Bool {
    if let workspaceURL = persistenceCoordinator.url {
      return saveWorkspace(to: workspaceURL)
    }
    return saveWorkspaceAs() != nil
  }

  @discardableResult
  private func saveWorkspaceAs() -> URL? {
    let panel = workspaceSavePanel(
      fileName: suggestedWorkspaceFileName,
      directoryURL: persistenceCoordinator.url?.deletingLastPathComponent()
        ?? iCloudDocumentsDirectory(),
      message: "Save the current LDTX Workspace.",
      prompt: "Save"
    )
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    let packageURL = persistenceCoordinator.packageURL(for: url)
    guard packageURL.standardizedFileURL != persistenceCoordinator.url?.standardizedFileURL else {
      return saveWorkspace(to: packageURL) ? packageURL : nil
    }
    do {
      let lock = try acquireWorkspaceLock(at: packageURL, createsPackageDirectory: true)
      var didActivateLock = false
      defer {
        if !didActivateLock { persistenceCoordinator.releaseLock(lock) }
      }
      guard saveWorkspace(to: packageURL) else { return nil }
      persistenceCoordinator.activateLock(lock)
      didActivateLock = true
      request = .file(packageURL)
      return packageURL
    } catch {
      appendLog("Workspace could not be saved: \(error.localizedDescription)")
      return nil
    }
  }

  /// Output is only allowed to cross the window boundary through a package
  /// that has been saved and locked by this editor instance.
  private func saveWorkspaceForOutput() -> URL? {
    if let workspaceURL = persistenceCoordinator.url {
      return saveWorkspace(to: workspaceURL) ? workspaceURL : nil
    }
    return saveWorkspaceAs()
  }

  private func ensureWorkspaceSavedForRename() -> URL? {
    if let workspaceURL = persistenceCoordinator.url {
      return saveWorkspace(to: workspaceURL) ? workspaceURL : nil
    }
    return saveWorkspaceAs()
  }

  private func ensureWorkspaceSavedForProgramSelection() -> URL? {
    if let workspaceURL = persistenceCoordinator.url {
      return saveWorkspace(to: workspaceURL) ? workspaceURL : nil
    }
    return saveWorkspaceAs()
  }

  /// Reopens the just-saved package while retaining this window's existing
  /// exclusive lock. Acquiring a second lock would incorrectly conflict with
  /// the same Workspace window.
  private func reloadWorkspaceAfterRename(
    at url: URL,
    initialSidebarItem: WorkspaceSidebarItem?
  ) -> Bool {
    do {
      let store = try persistenceCoordinator.load(at: url)
      try replaceWorkspaceStore(store, url: url)
      selectedSidebarItem = initialSidebarItem
      appendLog("Reopened Workspace after rename: \(url.path)")
      return true
    } catch {
      appendLog("Workspace could not be reopened after rename: \(error.localizedDescription)")
      return false
    }
  }

  private func reloadWorkspace() {
    guard outputSessionControlState == .idle,
      let url = persistenceCoordinator.url
    else { return }
    if hasUnsavedWorkspaceChanges {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Reload Workspace?"
      alert.informativeText =
        "Reloading replaces the current Workspace with the version on disk. Unsaved changes will be lost."
      alert.addButton(withTitle: "Reload")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }

    do {
      _ = try persistenceCoordinator.load(at: url)
    } catch {
      appendLog("Workspace could not be reloaded: \(error.localizedDescription)")
      return
    }

    let didBeginReload = windowCloseCoordinator.closeForReload {
      self.applicationRouter.workspaceOpenCoordinator.enqueue(url)
    }
    if !didBeginReload {
      appendLog("Workspace reload is already in progress.")
    }
  }

  private func switchToEditMode() {
    guard outputSessionControlState == .idle else { return }
    windowMode = .edit
  }

  private func acquireWorkspaceLock(
    at packageURL: URL,
    createsPackageDirectory: Bool = false
  ) throws -> WorkspaceLock {
    do {
      return try persistenceCoordinator.acquireLock(
        at: packageURL,
        createsPackageDirectory: createsPackageDirectory)
    } catch WorkspaceLockError.alreadyLocked(let conflict) {
      presentWorkspaceLockConflict(conflict)
      throw WorkspaceLockOpenError.cancelled
    }
  }

  private func presentWorkspaceLockConflict(_ conflict: WorkspaceLockConflict) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Workspace Is Locked"
    let details = conflict.comments.isEmpty ? "No lock details are available." : conflict.comments
    alert.informativeText =
      "This Workspace is open in another LDTX process.\n\n\(details)\n\nClose the other Workspace before opening it here."
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  @discardableResult
  private func saveWorkspace(to url: URL) -> Bool {
    do {
      saveCurrentProgramDefinitionIfNeeded()
      persistProgramLibraryAndOutputConfiguration()
      try persistenceCoordinator.save(persistenceCoordinator.store, to: url)
      persistenceCoordinator.replace(store: persistenceCoordinator.store, url: url)
      persistenceCoordinator.noteRecentDocument(url)
      updateWorkspaceWindowDirtyState()
      appendLog("Saved Workspace: \(url.path)")
      return true
    } catch {
      appendLog("Workspace could not be saved: \(error.localizedDescription)")
      return false
    }
  }

  private func workspaceSavePanel(
    fileName: String,
    directoryURL: URL?,
    message: String,
    prompt: String
  ) -> NSSavePanel {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.ldtxWorkspace]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.nameFieldStringValue = fileName
    panel.directoryURL = directoryURL
    panel.message = message
    panel.prompt = prompt
    return panel
  }

  private func iCloudDocumentsDirectory() -> URL? {
    let containerIdentifier = "iCloud.tokyo.kaito.ldtx.LDTX"
    let fileManager = FileManager.default
    guard let containerURL = fileManager.url(forUbiquityContainerIdentifier: containerIdentifier)
    else {
      return nil
    }

    let documentsURL = containerURL.appendingPathComponent("Documents", isDirectory: true)
    try? fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)
    return documentsURL
  }

  private var suggestedWorkspaceFileName: String {
    let name =
      persistenceCoordinator.url?.lastPathComponent
      ?? "\(persistenceCoordinator.store.definition.name).\(WorkspacePackageLayout.pathExtension)"
    return name.hasSuffix(".\(WorkspacePackageLayout.pathExtension)")
      ? name
      : "\(name).\(WorkspacePackageLayout.pathExtension)"
  }

  /// Commits the two editor-owned projections that are intentionally kept
  /// outside WorkspaceStore. All other Workspace domain values are direct
  /// projections of WorkspacePersistenceCoordinator.store.
  private func persistProgramLibraryAndOutputConfiguration() {
    let workspaceName =
      persistenceCoordinator.url?.deletingPathExtension().lastPathComponent
      ?? persistenceCoordinator.store.definition.name
    persistenceCoordinator.commitEditorProjections(
      workspaceName: workspaceName,
      programs: programLibrary.records,
      outputConfiguration: WorkspaceOutputConfiguration(
        profileID: outputCanvas.canvasSize.width == ProgramOutputProfile.sdr1080p60.width
          && outputCanvas.canvasSize.height == ProgramOutputProfile.sdr1080p60.height
          && outputCanvas.programDefinitionFrameRate == ProgramOutputProfile.sdr1080p60.frameRate
          ? .sdr1080p60 : nil,
        canvasWidth: outputCanvas.canvasSize.width,
        canvasHeight: outputCanvas.canvasSize.height,
        frameRate: outputCanvas.programDefinitionFrameRate,
        videoBitRate: persistenceCoordinator.store.definition.outputConfiguration.videoBitRate,
        portraitVideoBitRate:
          persistenceCoordinator.store.definition.outputConfiguration.portraitVideoBitRate,
        videoPTSMasterInputDeviceID: workspaceVideoPTSMasterInputDeviceID
      )
    )
  }

  private func replaceWorkspaceStore(
    _ incomingStore: WorkspaceStore,
    url: URL?,
    clearsDetailSelection: Bool = true
  ) throws {
    let store = incomingStore
    var recovered: [String] = []
    if store.definition.outputConfiguration.normalizedForOutputPreset() == nil {
      store.edit { definition in
        definition.outputConfiguration = WorkspaceOutputConfiguration(
          profileID: .sdr1080p60,
          canvasWidth: ProgramOutputProfile.sdr1080p60.width,
          canvasHeight: ProgramOutputProfile.sdr1080p60.height,
          frameRate: ProgramOutputProfile.sdr1080p60.frameRate,
          videoBitRate: ProgramOutputProfile.sdr1080p60.videoBitRate,
          videoPTSMasterInputDeviceID: definition.outputConfiguration.videoPTSMasterInputDeviceID
        )
      }
      recovered.append("Canvas preset")
    }
    if let normalized = store.preferences.outputDestination.normalized() {
      if normalized != store.preferences.outputDestination {
        store.editPreferences { $0.outputDestination = normalized }
      }
    } else {
      store.editPreferences { $0.outputDestination = .missingPersistedValueFallback }
      recovered.append("Output destination")
    }
    runtimeState.programRuntimePool.clear()
    persistenceCoordinator.replace(store: store, url: url)
    transientSelectedYouTubeBroadcastID = nil
    transientLandscapeLiveStreamID = nil
    transientPortraitLiveStreamID = nil
    outputCanvas.canvasSize = OutputCanvasModel.CanvasSize(
      width: store.definition.outputConfiguration.canvasWidth,
      height: store.definition.outputConfiguration.canvasHeight
    )
    outputCanvas.programDefinitionFrameRate = store.definition.outputConfiguration.frameRate
    synchronizeVisionResources()
    synchronizeVisionAnalysis()
    isProgramDefinitionDirty = false
    updateWorkspaceWindowDirtyState()
    let selectedName =
      store.preferences.selectedProgramName ?? store.definition.programs.first?.name
    try programLibrary.replaceRecords(store.definition.programs, selectedName: selectedName)
    let selectedRecord = try programLibrary.ensureDefaultProgram()
    persistProgramLibraryAndOutputConfiguration()
    selectProgramDefinition(
      named: selectedRecord.name, clearsDetailSelection: clearsDetailSelection)
    applyWorkspaceVideoComponentsToSelectedProgram()
    synchronizeInputDeviceCaptures()
    if !recovered.isEmpty {
      outputConfigurationRecoveryDescription =
        "LDTX reset \(recovered.joined(separator: " and ")) to the default SDR 1080p60 output configuration."
      if let url {
        try persistenceCoordinator.save(persistenceCoordinator.store, to: url)
      }
    }
  }

  private func applyWorkspaceVideoComponentsToSelectedProgram() {
    guard let selectedProgramDefinitionName else { return }
    compositeProgramDefinition = resolvedComposite(
      compositeProgramDefinition,
      programName: selectedProgramDefinitionName
    )
    portraitCompositeProgramDefinition = resolvedComposite(
      portraitCompositeProgramDefinition,
      programName: selectedProgramDefinitionName,
      preferences: persistenceCoordinator.portraitProgramPreferences,
      canvasWidth: 1_080,
      canvasHeight: 1_920
    )
  }

  private func resolvedComposite(
    _ composite: CompositeProgramDefinition,
    programName: String,
    preferences: ProgramPreferences? = nil,
    canvasWidth: Int = 1_920,
    canvasHeight: Int = 1_080
  ) -> CompositeProgramDefinition {
    WorkspaceVideoComponentResolver.applying(
      workspaceVideoComponents,
      layers: (preferences ?? programPreferences).videoLayers(forProgramNamed: programName),
      to: composite,
      coordinateWidth: Float(canvasWidth),
      coordinateHeight: Float(canvasHeight)
    )
  }

  private func updateWorkspaceWindowDirtyState() {
    windowCloseCoordinator.updateDocumentEdited(hasUnsavedWorkspaceChanges)
  }

  private func saveCurrentProgramDefinitionIfNeeded() {
    guard isProgramDefinitionDirty, let name = selectedProgramDefinitionName else { return }
    let record = SavedProgramDefinitionRecord(
      name: name,
      landscape: ProgramCanvasDefinition(
        canvasWidth: 1920, canvasHeight: 1080,
        frameRateNumerator: 60, frameRateDenominator: 1,
        composite: outputCanvas.applying(to: compositeProgramDefinition)),
      portrait: ProgramCanvasDefinition(
        canvasWidth: 1080, canvasHeight: 1920,
        frameRateNumerator: 60, frameRateDenominator: 1,
        composite: portraitCompositeProgramDefinition), inputDevices: [])
    if saveProgramDefinitionRecord(record) {
      isProgramDefinitionDirty = false
      updateWorkspaceWindowDirtyState()
    }
  }

  private var isWorkspaceSaveToolbarEnabled: Bool {
    hasUnsavedWorkspaceChanges || persistenceCoordinator.url == nil
  }

  private var applicationOutputPreferences: ApplicationOutputPreferences {
    guard !applicationOutputPreferencesData.isEmpty,
      let preferences = try? ApplicationOutputPreferencesPersistenceCodec.decode(
        from: applicationOutputPreferencesData
      )
    else { return ApplicationOutputPreferences() }
    return preferences
  }

  private func migrateLegacyApplicationOutputPreferencesIfNeeded() {
    guard
      let data =
        try? ApplicationOutputPreferencesPersistenceCodec
        .migrateLegacyOutputSettingsIfNeeded(
          currentData: applicationOutputPreferencesData,
          legacyData: legacyApplicationOutputSettingsData
        )
    else { return }
    applicationOutputPreferencesData = data
  }

  private var outputBaseDirectory: URL {
    if outputDestination.overridesOutputFolder,
      let path = outputDestination.outputFolderPath
    {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    if let path = applicationOutputPreferences.defaultOutputFolderPath, !path.isEmpty {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return localOutputStore.defaultBaseDirectory
  }

  private var isOutputSessionRunning: Bool {
    outputCoordinator.lifecycleState == .running
  }

  private var outputSessionControlState: OutputSessionControlState {
    outputCoordinator.lifecycleState
  }

  private var canStartOutputSession: Bool {
    !eventCoordinator.isLocked
      && shutdownCoordinator.shouldAllowResourceStart()
      && canBeginOutputSession
  }

  private var activeOutputProfile: ProgramOutputProfile? {
    let output = persistenceCoordinator.store.definition.outputConfiguration
    guard output.isSupportedOutputProfile else { return nil }
    return .sdr1080p60.withVideoBitRate(output.videoBitRate)
  }

  private var canBeginOutputSession: Bool {
    outputCoordinator.lifecycleState == .idle
      || outputCoordinator.lifecycleState == .readyToRestart
  }

  private var isStreamingToYouTube: Bool {
    isOutputSessionRunning && outputCoordinator.activeMode?.streamsToYouTube == true
  }

  private var isRecording: Bool {
    isOutputSessionRunning && outputCoordinator.activeMode?.recordsLocally == true
      && !outputCoordinator.isRecordFinalizing
  }

  private var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord? {
    savedProgramDefinition(named: selectedProgramDefinitionName)
  }

  private var selectedExistingBroadcast: YouTubeLiveBroadcast? {
    guard let transientSelectedYouTubeBroadcastID else {
      return nil
    }
    return existingBroadcasts.first { $0.id == transientSelectedYouTubeBroadcastID }
  }

  private var existingBroadcastSummaries: [LiveBroadcastSummary] {
    existingBroadcasts.compactMap { broadcast in
      guard let id = broadcast.id, !id.isEmpty else {
        return nil
      }
      let statusLabel: String?
      if let lifeCycleStatus = broadcast.status?.lifeCycleStatus, !lifeCycleStatus.isEmpty {
        statusLabel = lifeCycleStatus.capitalized
      } else if broadcast.snippet?.actualStartTime != nil {
        statusLabel = "Active"
      } else if broadcast.snippet?.scheduledStartTime != nil {
        statusLabel = "Upcoming"
      } else {
        statusLabel = nil
      }
      return LiveBroadcastSummary(
        id: id,
        title: broadcast.snippet?.title ?? "Untitled",
        statusLabel: statusLabel
      )
    }
  }

  private var preferredExistingBroadcast: YouTubeLiveBroadcast? {
    selectedExistingBroadcast ?? recommendedExistingBroadcast
  }

  private var recommendedExistingBroadcast: YouTubeLiveBroadcast? {
    let activeBroadcasts =
      existingBroadcasts
      .filter { broadcast in
        broadcast.snippet?.actualEndTime == nil
          && (broadcast.snippet?.actualStartTime != nil
            || broadcast.status?.lifeCycleStatus == "live")
      }
      .sorted { left, right in
        broadcastActivityDate(left) > broadcastActivityDate(right)
      }
    if let activeBroadcast = activeBroadcasts.first {
      return activeBroadcast
    }

    let upcomingBroadcasts =
      existingBroadcasts
      .filter { $0.snippet?.actualStartTime == nil }
      .sorted { left, right in
        broadcastScheduleDate(left) < broadcastScheduleDate(right)
      }
    if let upcomingBroadcast = upcomingBroadcasts.first {
      return upcomingBroadcast
    }

    return existingBroadcasts.first
  }

  private var isGlobalOutputSessionStartEnabled: Bool {
    if isLoadingBroadcasts || isConnectingBroadcast {
      return false
    }
    if !canStartOutputSession {
      return false
    }
    return true
  }

  private var canCreateLiveStream: Bool {
    if isLoadingBroadcasts || isConnectingBroadcast {
      return false
    }
    if isOutputSessionRunning {
      return false
    }
    return outputDestination.streamsToYouTube
  }

  private var globalOutputSessionStartAccessibilityLabel: String {
    switch outputDestination.enabledCaptureOutputMode {
    case .none:
      return "Start Output"
    case .youtube:
      return "Start Stream"
    case .record:
      return "Start Recording"
    case .youtubeAndRecord:
      return "Start Stream & Record"
    }
  }

  private var globalOutputSessionStopHelp: String {
    if isStreamingToYouTube && isRecording {
      return "Stop streaming and local recording."
    }
    if isStreamingToYouTube {
      return "Stop streaming to YouTube."
    }
    if isRecording {
      return "Stop local recording."
    }
    return "Stop output."
  }

  private var globalOutputSessionStartHelp: String {
    if outputDestination.streamsToYouTube,
      outputDestination.youtubeIngestMode == .dualRTMPS,
      transientLandscapeLiveStreamID == nil || transientPortraitLiveStreamID == nil
        || transientLandscapeLiveStreamID == transientPortraitLiveStreamID
    {
      return "Select different stream key configurations for Default and Vertical in Output."
    }
    if outputDestination.streamsToYouTube,
      outputDestination.youtubeIngestMode == .dash,
      preferredExistingBroadcast == nil
    {
      return "Create or schedule a YouTube broadcast in Manage before connecting."
    }

    switch outputDestination.enabledCaptureOutputMode {
    case .none:
      return "Enable Record or YouTube in Output."
    case .youtube:
      return "Connect to the active YouTube broadcast."
    case .record:
      return "Start local recording."
    case .youtubeAndRecord:
      return "Connect to YouTube and start local recording."
    }
  }

  private var effectiveWorkspaceAudioChannels: [ProgramAudioChannel] {
    programInputDevices.resolvedWorkspaceAudioChannels(from: workspaceAudioChannels)
  }

  @discardableResult
  private func synchronizeWorkspaceAudioChannelsWithInputDevices() -> Bool {
    let resolvedAudioChannels = programInputDevices.resolvedWorkspaceAudioChannels(
      from: workspaceAudioChannels
    )
    guard resolvedAudioChannels != workspaceAudioChannels else {
      return false
    }
    workspaceAudioChannels = resolvedAudioChannels
    return true
  }

  private var canStartProgramAudioMix: Bool {
    let landscapeAudioChannels = compositeProgramDefinition.audioChannels
    let portraitAudioChannels = portraitCompositeProgramDefinition.audioChannels
    guard !landscapeAudioChannels.isEmpty, !portraitAudioChannels.isEmpty else {
      return false
    }

    let landscapeMappings = mappedInputAudioDeviceIDs(
      composite: compositeProgramDefinition,
      audioChannels: landscapeAudioChannels,
      workspaceInputDevices: programInputDevices,
      inputAudioDeviceMappings: inputAudioDeviceMappings
    )
    for channel in landscapeAudioChannels
    where channel.component.definition.usesInputAudioDevice {
      let key = landscapeAudioChannels.inputAudioDeviceMappingKey(for: channel)
      guard landscapeMappings[key]?.isEmpty == false else {
        return false
      }
    }
    let portraitMappings = mappedInputAudioDeviceIDs(
      composite: portraitCompositeProgramDefinition,
      audioChannels: portraitAudioChannels,
      workspaceInputDevices: programInputDevices,
      inputAudioDeviceMappings: inputAudioDeviceMappings
    )
    for channel in portraitAudioChannels
    where channel.component.definition.usesInputAudioDevice {
      let key = portraitAudioChannels.inputAudioDeviceMappingKey(for: channel)
      guard portraitMappings[key]?.isEmpty == false else {
        return false
      }
    }
    return true
  }

  private func savedProgramDefinition(named name: String?) -> SavedProgramDefinitionRecord? {
    guard let name else {
      return nil
    }
    return programLibrary.records.first { $0.name == name }
  }

  private func refreshSavedProgramDefinitions() {
    reloadSavedProgramDefinitions()
  }

  private func reloadSavedProgramDefinitions() {
    do {
      try programLibrary.reload()
      let selectedRecord = try programLibrary.ensureDefaultProgram()
      persistProgramLibraryAndOutputConfiguration()
      selectProgramDefinition(named: selectedRecord.name, clearsDetailSelection: false)
    } catch {
      programLibrary.resetAfterRestoreFailure()
      appendLog("Stored program definitions could not be restored and were reset.")
      addProgramDefinition()
    }
  }

  @discardableResult
  private func selectProgramDefinition(
    named name: String?,
    clearsDetailSelection: Bool = true
  ) -> Bool {
    guard !(windowMode == .output && outputCoordinator.isProgramRuntimeTransitioning) else {
      return false
    }
    let previouslySelectedName = selectedProgramDefinitionName
    let selectedName = name ?? programLibrary.records.first?.name
    if windowMode == .output, let record = savedProgramDefinition(named: selectedName) {
      let landscapeConfiguration = programConfiguration(for: record, role: .landscape)
      let portraitConfiguration = programConfiguration(for: record, role: .portrait)
      guard !landscapeConfiguration.audioChannels.isEmpty,
        !portraitConfiguration.audioChannels.isEmpty,
        hasValidAudioDeviceMappings(landscapeConfiguration),
        hasValidAudioDeviceMappings(portraitConfiguration)
      else { return false }
    }
    // A Program switch is a Workspace boundary: commit the current Program and
    // Preferences before replacing the editor projection with another Program.
    // This preserves live Destination edits made in Output mode as well.
    if previouslySelectedName != nil,
      selectedName != previouslySelectedName,
      ensureWorkspaceSavedForProgramSelection() == nil
    {
      return false
    }
    if clearsDetailSelection {
      clearDetailSelection()
    }
    selectedProgramDefinitionName = selectedName
    persistenceCoordinator.store.editPreferences { $0.selectedProgramName = selectedName }
    persistWorkspacePreferences()
    if let record = savedProgramDefinition(named: selectedName) {
      compositeProgramDefinition = record.composite
      portraitCompositeProgramDefinition = record.portrait.composite
      applyWorkspaceVideoComponentsToSelectedProgram()
      synchronizeWorkspaceAudioChannelsWithInputDevices()
      isProgramDefinitionDirty = false
      updateWorkspaceWindowDirtyState()
    } else {
      synchronizeWorkspaceAudioChannelsWithInputDevices()
    }
    restartAudioMonitor()
    synchronizeInputDeviceCaptures()
    updateSelectedProgramRuntime()
    if windowMode == .output {
      guard
        outputCoordinator.currentSession?.switchProgramRuntimes(
          landscape: selectedProgramRuntime,
          portrait: selectedPortraitProgramRuntime
        ) != false
      else {
        return false
      }
      if let session = outputCoordinator.currentSession,
        let record = savedProgramDefinition(named: selectedName)
      {
        let landscapeConfiguration = programConfiguration(for: record, role: .landscape)
        let portraitConfiguration = programConfiguration(for: record, role: .portrait)
        _ = session.landscape.reconfigureAudio(
          programPreferences: programPreferences,
          audioDeviceIDsByInputKey: mappedInputAudioDeviceIDs(
            composite: landscapeConfiguration.composite,
            audioChannels: landscapeConfiguration.audioChannels,
            workspaceInputDevices: programInputDevices,
            inputAudioDeviceMappings: inputAudioDeviceMappings))
        session.configurePortrait(
          preferences: persistenceCoordinator.portraitProgramPreferences,
          audioDeviceIDsByInputKey: mappedInputAudioDeviceIDs(
            composite: portraitConfiguration.composite,
            audioChannels: portraitConfiguration.audioChannels,
            workspaceInputDevices: programInputDevices,
            inputAudioDeviceMappings: inputAudioDeviceMappings))
      }
    }
    return true
  }

  private func clearDetailSelection() {
    selectedSidebarItem = .output
  }

  private func restoreAppPreviewSettings() {
    guard !appPreviewSettingsData.isEmpty else { return }
    guard
      let settings = try? AppPreviewSettingsPersistenceCodec.decode(
        from: appPreviewSettingsData
      )
    else {
      appendLog("App Preview Settings could not be decoded; using defaults.")
      return
    }
    previewSettings = settings
  }

  private func persistPreviewSettings() {
    do {
      appPreviewSettingsData = try AppPreviewSettingsPersistenceCodec.encode(previewSettings)
    } catch {
      appendLog("App Preview Settings could not be saved: \(error.localizedDescription)")
    }
  }

  private func persistWorkspacePreferences() {
    persistProgramLibraryAndOutputConfiguration()
    let snapshots = WorkspacePreferenceSnapshots(
      programPreferences: programPreferences,
      physicalDeviceIDsByInputDeviceID: programInputDevices.reduce(into: [:]) {
        mappings, device in
        guard let physicalDeviceID = device.physicalDeviceID,
          !physicalDeviceID.isEmpty,
          mappings[device.id] == nil
        else {
          return
        }
        mappings[device.id] = physicalDeviceID
      },
      inputCameraDeviceMappings: inputCameraDeviceMappings,
      inputAudioDeviceMappings: inputAudioDeviceMappings,
      inputAudioMonitorChannelKeys: inputAudioPassthroughChannelKeys,
      selectedProgramName: selectedProgramDefinitionName,
      outputDestination: outputDestination
    )
    persistenceCoordinator.store.editPreferences { preferences in
      snapshots.apply(to: &preferences)
    }
    guard let workspaceURL = persistenceCoordinator.url else { return }
    let store = persistenceCoordinator.store
    persistenceCoordinator.scheduleAutomaticSave(
      store,
      to: workspaceURL
    ) { result in
      switch result {
      case .success:
        guard self.persistenceCoordinator.store === store,
          self.persistenceCoordinator.url?.standardizedFileURL == workspaceURL.standardizedFileURL
        else { return }
        self.persistenceCoordinator.replace(
          store: store,
          url: workspaceURL
        )
        self.updateWorkspaceWindowDirtyState()
      case .failure(let error):
        self.appendLog("Workspace could not be saved: \(error.localizedDescription)")
      }
    }
  }

  private func saveProgramDefinitionRecord(_ record: SavedProgramDefinitionRecord) -> Bool {
    do {
      try programLibrary.save(record)
      persistProgramLibraryAndOutputConfiguration()
      persistWorkspacePreferences()
      return true
    } catch {
      appendLog("Program definitions could not be saved: \(error.localizedDescription)")
      return false
    }
  }

  private func addProgramDefinition() {
    do {
      let record = try programLibrary.appendEmpty()
      persistProgramLibraryAndOutputConfiguration()
      selectProgramDefinition(named: record.name)
    } catch let error as ProgramLibraryError {
      programAddErrorMessage = error.localizedDescription
    } catch {
      appendLog("Program definitions could not be saved: \(error.localizedDescription)")
    }
  }

  private func addProgramDefinition(named name: String) {
    guard windowMode == .edit, !eventCoordinator.isLocked else { return }
    do {
      let record = try programLibrary.appendEmpty(named: name)
      persistProgramLibraryAndOutputConfiguration()
      selectProgramDefinition(named: record.name)
    } catch let error as ProgramLibraryError {
      programAddErrorMessage = error.localizedDescription
    } catch {
      appendLog("Program definitions could not be saved: \(error.localizedDescription)")
    }
  }

  @discardableResult
  private func renameProgramDefinition(oldName: String, to proposedName: String) -> Bool {
    guard windowMode == .edit, !eventCoordinator.isLocked else { return false }
    let newName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !newName.isEmpty, newName != oldName,
      programLibrary.records.contains(where: { $0.name == oldName }),
      let workspaceURL = ensureWorkspaceSavedForRename()
    else {
      return false
    }
    isRenamingWorkspaceResource = true
    defer { isRenamingWorkspaceResource = false }
    return replaceWorkspaceForRename(
      at: workspaceURL,
      initialSidebarItem: .programs,
      mutation: { definition, preferences in
        try definition.renameProgram(from: oldName, to: newName, preferences: &preferences)
      })
  }

  private func deleteProgramDefinition(named name: String) {
    guard windowMode == .edit, !eventCoordinator.isLocked,
      selectedProgramDefinitionName != name
    else {
      return
    }
    do {
      try programLibrary.delete(named: name)
      var preferences = programPreferences
      preferences.removeProgramReference(named: name)
      replaceProgramPreferences(with: preferences)
      var portraitPreferences = persistenceCoordinator.portraitProgramPreferences
      portraitPreferences.removeProgramReference(named: name)
      persistenceCoordinator.replacePortraitProgramPreferences(with: portraitPreferences)
      runtimeState.programRuntimePool.removeRuntime(named: name)
      persistProgramLibraryAndOutputConfiguration()
      persistWorkspacePreferences()
    } catch {
      appendLog("Program definitions could not be saved: \(error.localizedDescription)")
    }
  }

  private func moveProgramDefinition(named name: String, by offset: Int) {
    guard windowMode == .edit, !eventCoordinator.isLocked else { return }
    do {
      guard try programLibrary.move(named: name, by: offset) else { return }
      persistProgramLibraryAndOutputConfiguration()
      persistWorkspacePreferences()
    } catch {
      appendLog("Program definitions could not be reordered: \(error.localizedDescription)")
    }
  }

  private func deleteWorkspaceInputDevice(id: String) {
    guard windowMode == .edit, !eventCoordinator.isLocked else { return }
    saveCurrentProgramDefinitionIfNeeded()
    var removedLandscapeLayerNamesByProgram: [String: Set<String>] = [:]
    var removedPortraitLayerNamesByProgram: [String: Set<String>] = [:]
    guard
      mutateWorkspaceDefinition(
        { definition in
          for program in definition.programs {
            removedLandscapeLayerNamesByProgram[program.name, default: []].formUnion(
              program.landscape.composite.steps.compactMap { step in
                guard case .inputCameraDevice(let payload) = step.component,
                  payload.inputDeviceID == id
                else { return nil }
                return step.name
              })
            removedPortraitLayerNamesByProgram[program.name, default: []].formUnion(
              program.portrait.composite.steps.compactMap { step in
                guard case .inputCameraDevice(let payload) = step.component,
                  payload.inputDeviceID == id
                else { return nil }
                return step.name
              })
          }
          return definition.removeInputDevice(named: id)
        },
        updatePreferences: { preferences in
          preferences.removeInputDevice(named: id)
          for (programName, layerNames) in removedLandscapeLayerNamesByProgram {
            for layerName in layerNames {
              preferences.programPreferences.removeVideoComponentReference(
                named: layerName, fromProgramNamed: programName)
            }
          }
          for (programName, layerNames) in removedPortraitLayerNamesByProgram {
            for layerName in layerNames {
              preferences.portraitProgramPreferences.removeVideoComponentReference(
                named: layerName, fromProgramNamed: programName)
            }
          }
        })
    else { return }
    if let replacementID = programInputDevices.first?.id {
      selectedSidebarItem = .inputDevice(replacementID)
    } else {
      clearDetailSelection()
    }
    persistWorkspacePreferences()
    synchronizeInputDeviceCaptures()
    restartAudioMonitor()
  }

  private func deleteWorkspaceVision(id: String) {
    guard !eventCoordinator.isLocked else { return }
    guard mutateWorkspaceDefinition({ $0.removeVision(named: id) }) else { return }
    selectedSidebarItem = .output
    persistWorkspacePreferences()
  }

  @discardableResult
  private func mutateWorkspaceDefinition(
    _ mutation: (inout WorkspaceDefinition) -> Bool,
    updatePreferences: (inout WorkspacePreferences) -> Void = { _ in }
  ) -> Bool {
    persistProgramLibraryAndOutputConfiguration()
    var definition = persistenceCoordinator.store.definition
    var preferences = persistenceCoordinator.store.preferences
    guard mutation(&definition) else { return false }
    updatePreferences(&preferences)

    do {
      try programLibrary.replaceRecords(
        definition.programs,
        selectedName: selectedProgramDefinitionName
      )
    } catch {
      appendLog("Workspace resource references could not be updated: \(error.localizedDescription)")
      return false
    }

    persistenceCoordinator.store.edit { currentDefinition in
      currentDefinition = definition
    }
    persistenceCoordinator.replacePreferences(with: preferences)
    if let selectedRecord = programLibrary.records.first(where: {
      $0.name == selectedProgramDefinitionName
    }) {
      compositeProgramDefinition = resolvedComposite(
        selectedRecord.composite,
        programName: selectedRecord.name
      )
      portraitCompositeProgramDefinition = resolvedComposite(
        selectedRecord.portrait.composite,
        programName: selectedRecord.name,
        preferences: preferences.portraitProgramPreferences,
        canvasWidth: selectedRecord.portrait.canvasWidth,
        canvasHeight: selectedRecord.portrait.canvasHeight
      )
    }
    replaceProgramPreferences(with: preferences.programPreferences)
    return true
  }

  private func deleteWorkspaceVideoComponent(id: String) {
    guard windowMode == .edit else { return }
    saveCurrentProgramDefinitionIfNeeded()

    var updatedComposite = compositeProgramDefinition
    updatedComposite.steps.removeAll { $0.id == id }
    var updatedPortraitComposite = portraitCompositeProgramDefinition
    updatedPortraitComposite.steps.removeAll { $0.id == id }

    do {
      let records = programLibrary.records.map { record in
        var updated = record
        updated.landscape.composite.steps.removeAll { $0.id == id }
        updated.portrait.composite.steps.removeAll { $0.id == id }
        return updated
      }
      try programLibrary.replaceRecords(records, selectedName: selectedProgramDefinitionName)
    } catch {
      appendLog("Video Component could not be removed from Programs: \(error.localizedDescription)")
      return
    }

    compositeProgramDefinition = updatedComposite
    portraitCompositeProgramDefinition = updatedPortraitComposite
    workspaceVideoComponents.removeAll { $0.id == id }
    var preferences = programPreferences
    preferences.removeVideoComponentReference(named: id)
    replaceProgramPreferences(with: preferences)
    var portraitPreferences = persistenceCoordinator.portraitProgramPreferences
    portraitPreferences.removeVideoComponentReference(named: id)
    persistenceCoordinator.replacePortraitProgramPreferences(with: portraitPreferences)
    selectedSidebarItem = .output
    persistProgramLibraryAndOutputConfiguration()
    updateWorkspaceWindowDirtyState()
  }

  private var monitorPreferences: ProgramPreferences {
    programPreferences.monitorMixPreferences
  }

  private func updateMasterMeterGains() {
    audioCoordinator.peakMeter.updateMasterGains(
      channels: compositeProgramDefinition.audioChannels,
      landscape: programPreferences,
      portrait: persistenceCoordinator.portraitProgramPreferences)
  }

  private func updateAudioMixGains() {
    updateMasterMeterGains()
    audioCoordinator.monitor.updateGains(
      audioChannels: compositeProgramDefinition.audioChannels,
      preferences: monitorPreferences,
      inputPassthroughChannelKeys: inputAudioPassthroughChannelKeys)
  }

  @discardableResult
  private func restartAudioMonitor() -> Bool {
    shutdownCoordinator.requestStart { _ in
      await self.performRestartAudioMonitor().value
    }
  }

  private func performRestartAudioMonitor() -> Task<Void, Never> {
    updateMasterMeterGains()
    let composite = compositeProgramDefinition
    let audioChannels = composite.audioChannels
    let inputAudioDeviceMappings = inputAudioDeviceMappings
    let workspaceInputDevices = programInputDevices
    let resolvedInputAudioDeviceMappings = mappedInputAudioDeviceIDs(
      composite: composite,
      audioChannels: audioChannels,
      workspaceInputDevices: workspaceInputDevices,
      inputAudioDeviceMappings: inputAudioDeviceMappings
    )
    let programPreferences = monitorPreferences
    let inputPassthroughChannelKeys = inputAudioPassthroughChannelKeys
    return audioCoordinator.restart(
      audioChannels: audioChannels,
      inputAudioDeviceMappings: resolvedInputAudioDeviceMappings,
      programPreferences: programPreferences,
      inputPassthroughChannelKeys: inputPassthroughChannelKeys,
      shouldRemainRunning: shutdownCoordinator.shouldAllowResourceStart,
      failureHandler: { failure in
        self.appendLog("Audio monitor interrupted: \(self.errorDescription(failure))")
      },
      errorHandler: { error in
        self.appendLog("Audio monitor failed: \(self.errorDescription(error))")
      }
    )
  }

  private func workspaceInputDevicesChanged() {
    let didChangeAudioChannels = synchronizeWorkspaceAudioChannelsWithInputDevices()
    synchronizeInputDeviceCaptures()
    if !didChangeAudioChannels {
      restartAudioMonitor()
    }
    updateSelectedProgramRuntime()
  }

  private func analyzeVision(_ vision: WorkspaceVisionDefinition) {
    guard workspaceFeatureAvailability.supportsVision,
      outputCoordinator.lifecycleState == .running
    else { return }
    visionFeature.submit(
      vision,
      source: .manual,
      context: visionFeatureContext
    )
  }

  private func synchronizeVisionResources() {
    guard workspaceFeatureAvailability.supportsVision else { return }
    visionFeature.synchronizeModels(visions: visions)
  }

  private func synchronizeVisionAnalysis() {
    guard workspaceFeatureAvailability.supportsVision else {
      visionFeature.stopAnalysis()
      return
    }
    visionFeature.synchronize(
      visions: visions,
      context: visionFeatureContext
    )
  }

  private func stopVisionTasks() async {
    await withCheckedContinuation { continuation in
      visionFeature.stopAnalysis { continuation.resume() }
    }
  }

  private var visionFeatureContext: WorkspaceVisionFeatureContext {
    WorkspaceVisionFeatureContext(
      isSessionRunning: { self.outputCoordinator.lifecycleState == .running },
      visionNamed: { id in self.visions.first { $0.id == id } },
      frameForVision: frameForVision(_:),
      beginRecordingOperation: {
        guard let lease = self.outputCoordinator.beginRecordAuxiliaryOperation() else { return nil }
        return WorkspaceVisionRecordingLease(
          packageDirectory: lease.packageDirectory,
          timelineMilliseconds: lease.timelineMilliseconds,
          releaseHandler: {
            Task { @MainActor in
              self.outputCoordinator.endRecordAuxiliaryOperation(lease)
            }
          })
      },
      presentRecordingFailure: { error in
        self.visionRecordingFailureDescription = error.localizedDescription
      },
      appendLog: appendLog(_:)
    )
  }

  private func frameForVision(
    _ vision: WorkspaceVisionDefinition
  ) throws -> WorkspaceVisionAnalysisFrame {
    let sourceFrame: WorkspaceVisionAnalysisFrame?
    switch vision.source {
    case .landscapeProgramOutput:
      sourceFrame = selectedProgramRuntime.latestFrame().map {
        WorkspaceVisionAnalysisFrame(
          image: CIImage(cvPixelBuffer: $0.pixelBuffer)
        )
      }
    case .portraitProgramOutput:
      sourceFrame = selectedPortraitProgramRuntime.latestFrame().map {
        WorkspaceVisionAnalysisFrame(
          image: CIImage(cvPixelBuffer: $0.pixelBuffer)
        )
      }
    case .inputDevice(let id):
      guard let inputDevice = programInputDevices.first(where: { $0.id == id }) else {
        throw WorkspaceVisionFeatureError.referencedInputDeviceMissing
      }
      guard let physicalDeviceID = inputDevice.physicalDeviceID else {
        throw WorkspaceVisionFeatureError.inputDeviceHasNoPhysicalCamera
      }
      sourceFrame = workspaceCaptureSessionCoordinator.latestVisionFrame(
        forCameraID: physicalDeviceID
      ).map {
        WorkspaceVisionAnalysisFrame(
          image: CIImage(cvPixelBuffer: $0.pixelBuffer)
        )
      }
    }
    guard let sourceFrame else {
      throw WorkspaceVisionFeatureError.frameUnavailable
    }
    let image = sourceFrame.image
    let crop = vision.sourceCrop
    let left = CGFloat(min(max(crop.left, 0), 100)) / 100
    let right = CGFloat(min(max(crop.right, 0), 100)) / 100
    let top = CGFloat(min(max(crop.top, 0), 100)) / 100
    let bottom = CGFloat(min(max(crop.bottom, 0), 100)) / 100
    let availableWidth = 1 - left - right
    let availableHeight = 1 - top - bottom
    guard availableWidth > 0, availableHeight > 0 else {
      throw WorkspaceVisionFeatureError.invalidSourceCrop
    }
    // Normalized width and height must remain equal for the cropped image to
    // retain the source aspect ratio. Honor every requested edge, then center
    // the largest source-aspect rectangle inside the remaining area.
    let normalizedSize = min(availableWidth, availableHeight)
    let normalizedX = left + (availableWidth - normalizedSize) / 2
    let normalizedY = bottom + (availableHeight - normalizedSize) / 2
    let extent = image.extent
    return WorkspaceVisionAnalysisFrame(
      image: image.cropped(
        to: CGRect(
          x: extent.minX + extent.width * normalizedX,
          y: extent.minY + extent.height * normalizedY,
          width: extent.width * normalizedSize,
          height: extent.height * normalizedSize
        )))
  }

  private func refreshExistingBroadcasts() {
    Task {
      isLoadingBroadcasts = true
      defer { isLoadingBroadcasts = false }

      do {
        let broadcasts = try await loadExistingBroadcasts()
        existingBroadcasts = broadcasts
        appendLog("Loaded \(broadcasts.count) active/upcoming YouTube broadcast(s).")
      } catch {
        appendLog("Broadcast list failed: \(errorDescription(error))")
        logError("Broadcast list failed", error: error)
      }
    }
  }

  private func saveStreamKeyConfigurations(_ configurations: [YouTubeRTMPSStreamKeyConfiguration])
    throws
  {
    guard !streamKeyConfigurationsLoadFailed else {
      throw YouTubeStreamKeyConfigurationStore.StoreError.loadFailed
    }
    try YouTubeStreamKeyConfigurationStore().save(configurations)
    streamKeyConfigurations = configurations
    if !configurations.contains(where: { $0.id == transientLandscapeLiveStreamID }) {
      transientLandscapeLiveStreamID = nil
    }
    if !configurations.contains(where: { $0.id == transientPortraitLiveStreamID }) {
      transientPortraitLiveStreamID = nil
    }
  }

  private func importStreamKeyConfiguration(_ id: String) async throws
    -> YouTubeRTMPSStreamKeyConfiguration
  {
    let accessToken = try await authState.validAccessToken(
      configuration: oauthClientState.configuration)
    return try await youtubeClientService.streamKeyConfiguration(accessToken: accessToken, id: id)
  }

  private func refreshExistingLiveStreams() {
    Task {
      isLoadingBroadcasts = true
      defer { isLoadingBroadcasts = false }
      do {
        let accessToken = try await authState.validAccessToken(
          configuration: oauthClientState.configuration)
        let choices = try await youtubeClientService.refreshExistingLiveStreams(
          accessToken: accessToken)
        existingLiveStreams = choices.map {
          LiveStreamSummary(id: $0.id, title: $0.title, statusLabel: $0.statusLabel)
        }
        appendLog("Loaded \(choices.count) RTMPS-compatible YouTube LiveStream(s).")
      } catch {
        appendLog("LiveStream list failed: \(errorDescription(error))")
        logError("LiveStream list failed", error: error)
      }
    }
  }

  private func loadExistingBroadcasts() async throws -> [YouTubeLiveBroadcast] {
    let accessToken = try await authState.validAccessToken(
      configuration: oauthClientState.configuration
    )
    let broadcasts = try await youtubeClientService.refreshExistingBroadcasts(
      accessToken: accessToken
    )
    if authState.channelID == nil {
      authState.refreshChannelID(configuration: oauthClientState.configuration)
    }
    return broadcasts
  }

  private func manageYouTubeBroadcasts() {
    if let url = youtubeLiveManagementURL(channelID: knownYouTubeChannelID) {
      appendLog("Opening YouTube Live management: \(url.absoluteString)")
      NSWorkspace.shared.open(url)
      return
    }

    Task {
      do {
        let accessToken = try await authState.validAccessToken(
          configuration: oauthClientState.configuration
        )
        let channelID = try await youtubeClientService.authenticatedChannelID(
          accessToken: accessToken)
        authState.refreshChannelID(configuration: oauthClientState.configuration)

        guard let url = youtubeLiveManagementURL(channelID: channelID) else {
          appendLog("YouTube channel ID is unavailable.")
          return
        }
        appendLog("Opening YouTube Live management: \(url.absoluteString)")
        NSWorkspace.shared.open(url)
      } catch {
        appendLog("YouTube channel ID lookup failed: \(errorDescription(error))")
        logError("YouTube channel ID lookup failed", error: error)
      }
    }
  }

  private func openYouTubeStreamConsole() {
    guard let broadcastID = normalizedBroadcastID(transientSelectedYouTubeBroadcastID),
      let url = URL(
        string: "https://studio.youtube.com/video/\(broadcastID)/livestreaming/console")
    else { return }
    openInSafari(url)
  }

  private func openYouTubeLiveChat() {
    guard let broadcastID = normalizedBroadcastID(transientSelectedYouTubeBroadcastID),
      var components = URLComponents(string: "https://www.youtube.com/live_chat")
    else { return }
    components.queryItems = [
      URLQueryItem(name: "is_popout", value: "1"),
      URLQueryItem(name: "v", value: broadcastID),
    ]
    guard let url = components.url else { return }
    openInSafari(url)
  }

  private func openYouTubeLiveControlRoom() {
    guard let broadcastID = normalizedBroadcastID(transientSelectedYouTubeBroadcastID),
      let url = URL(string: "https://studio.youtube.com/video/\(broadcastID)/livestreaming")
    else { return }
    openInSafari(url)
  }

  private func openInSafari(_ url: URL) {
    guard
      let safariURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.apple.Safari")
    else {
      appendLog("Safari is unavailable; opening external tool in the default browser.")
      NSWorkspace.shared.open(url)
      return
    }
    NSWorkspace.shared.open(
      [url],
      withApplicationAt: safariURL,
      configuration: NSWorkspace.OpenConfiguration()
    )
  }

  private func connectYouTube(
    broadcast: YouTubeLiveBroadcast?,
    operationID: UUID,
    logger: EventTaskLogger
  ) async {
    let broadcastID = broadcast?.id
    if outputDestination.youtubeIngestMode == .dash, broadcastID == nil {
      appendLog("YouTube broadcast is missing an ID.")
      markOutputSessionReadyToRestart(operationID: operationID)
      return
    }
    guard let outputMode = outputDestination.enabledCaptureOutputMode,
      outputMode.streamsToYouTube
    else {
      appendLog("Select YouTube or YouTube+Record before connecting a broadcast.")
      markOutputSessionReadyToRestart(operationID: operationID)
      return
    }
    guard !compositeProgramDefinition.audioChannels.isEmpty else {
      appendLog("Configure a Workspace Audio Channel before starting output.")
      markOutputSessionReadyToRestart(operationID: operationID)
      return
    }
    guard outputCoordinator.lifecycleState == .starting,
      outputCoordinator.operationID == operationID
    else {
      return
    }

    isConnectingBroadcast = true
    defer { isConnectingBroadcast = false }

    do {
      let configuration = activeProgramConfiguration()
      let portraitConfiguration = selectedProgramDefinitionRecord.map {
        programConfiguration(for: $0, role: .portrait)
      }
      selectedProgramRuntime.updateProgram(configuration)
      try await requestRequiredCaptureAccess(
        configurations: [configuration] + (portraitConfiguration.map { [$0] } ?? []))
      guard await synchronizeResourcesAfterRequiredCaptureAccess() else { return }
      let accessToken: String?
      if outputDestination.youtubeIngestMode == .dash {
        accessToken = try await authState.validAccessToken(
          configuration: oauthClientState.configuration)
      } else {
        accessToken = nil
      }
      guard outputCoordinator.operationID == operationID,
        outputCoordinator.lifecycleState == .starting
      else {
        return
      }
      var dashResult: YouTubeClientService.DASHStreamResult?
      var rtmpsDestinations: YouTubeDualRTMPSDestinations?
      switch outputDestination.youtubeIngestMode {
      case .dash:
        guard let accessToken, let broadcast, let broadcastID else {
          throw YouTubeClientServiceError.missingExistingBroadcastSelection
        }
        transientSelectedYouTubeBroadcastID = broadcastID
        dashResult = try await youtubeClientService.createDASHStream(
          accessToken: accessToken,
          request: YouTubeClientService.DASHStreamRequest(
            title: broadcast.snippet?.title ?? "LDTX",
            description: "",
            resolution: derivedYouTubeStreamResolution,
            frameRate: derivedYouTubeStreamFrameRate,
            usesTemporaryStream: true,
            existingBroadcast: broadcast))
      case .dualRTMPS:
        guard let landscapeID = transientLandscapeLiveStreamID,
          let portraitID = transientPortraitLiveStreamID
        else {
          throw YouTubeClientServiceError.missingDualRTMPSLiveStreamSelection
        }
        guard let landscape = streamKeyConfigurations.first(where: { $0.id == landscapeID }),
          let portrait = streamKeyConfigurations.first(where: { $0.id == portraitID })
        else { throw YouTubeClientServiceError.missingDualRTMPSLiveStreamSelection }
        rtmpsDestinations = try YouTubeDualRTMPSDestinations(
          landscape: landscape.destination(), portrait: portrait.destination())
      }
      if outputDestination.youtubeIngestMode == .dash, authState.channelID == nil {
        authState.refreshChannelID(configuration: oauthClientState.configuration)
      }
      guard outputCoordinator.operationID == operationID,
        outputCoordinator.lifecycleState == .starting
      else {
        do {
          if let dashResult, let accessToken {
            try await youtubeClientService.rollbackDASHStreamCreation(
              accessToken: accessToken,
              result: dashResult)
          }
        } catch {
          logError("Cancelled YouTube broadcast cleanup failed", error: error)
          appendLog("Cancelled YouTube broadcast cleanup failed: \(errorDescription(error))")
        }
        return
      }
      if outputDestination.youtubeIngestMode == .dash, dashResult?.dashEndpoint == nil {
        throw YouTubeDualRTMPSConfigurationError.missingDestination
      }

      let youtubeOutputServiceProcess: YouTubeOutputServiceProcessClient?
      let sharedH264Service: ProgramOutputSharedH264Service?
      if outputDestination.youtubeIngestMode == .dash {
        let process =
          outputCoordinator.youtubeOutputServiceProcess ?? YouTubeOutputServiceProcessClient()
        outputCoordinator.youtubeOutputServiceProcess = process
        youtubeOutputServiceProcess = process
        let service = try ProgramOutputSharedH264Service()
        outputCoordinator.sharedH264Service = service
        sharedH264Service = service
      } else {
        youtubeOutputServiceProcess = nil
        sharedH264Service = nil
      }
      let mediaHub = ProgramOutputMediaHub()
      let portraitMediaHub = ProgramOutputMediaHub()
      let session = ActiveDualProgramOutputSession(
        landscapeRuntime: selectedProgramRuntime,
        portraitRuntime: selectedPortraitProgramRuntime,
        captureSessionCoordinator: workspaceCaptureSessionCoordinator,
        landscapeMediaHub: mediaHub,
        portraitMediaHub: portraitMediaHub,
        portraitPreferences: persistenceCoordinator.portraitProgramPreferences,
        portraitAudioDeviceIDsByInputKey: portraitConfiguration.map {
          mappedInputAudioDeviceIDs(
            composite: $0.composite,
            audioChannels: $0.audioChannels,
            workspaceInputDevices: programInputDevices,
            inputAudioDeviceMappings: inputAudioDeviceMappings)
        } ?? [:],
        programRuntimeTransitionStateHandler: { [weak outputCoordinator] isTransitioning in
          outputCoordinator?.isProgramRuntimeTransitioning = isTransitioning
        }
      )
      outputCoordinator.currentMediaHub = mediaHub
      outputCoordinator.portraitMediaHub = portraitMediaHub
      outputCoordinator.currentSession = session
      createSessionTaskQueue()
      synchronizeVisionAnalysis()
      if outputMode.recordsLocally {
        localOutputStore.beginAccess(to: outputBaseDirectory)
      }
      let audioDeviceIDsByInputKey = mappedInputAudioDeviceIDs(
        composite: configuration.composite,
        audioChannels: configuration.audioChannels,
        workspaceInputDevices: programInputDevices,
        inputAudioDeviceMappings: inputAudioDeviceMappings
      )
      let outputFailureHandler: @MainActor (Error) -> Void = { error in
        guard self.outputCoordinator.operationID == operationID else { return }
        self.reportOutputFailure(
          error,
          source: .outputSession,
          operationID: operationID,
          outputMode: outputMode
        )
      }
      let youtubeFailureHandler: @MainActor (Error) -> Void = { error in
        guard self.outputCoordinator.operationID == operationID else { return }
        self.reportOutputFailure(
          error,
          source: .youtube,
          operationID: operationID,
          outputMode: outputMode
        )
      }
      let recordFailureHandler: @MainActor (Error) -> Void = { error in
        guard self.outputCoordinator.operationID == operationID else { return }
        self.reportOutputFailure(
          error,
          source: .recording,
          operationID: operationID,
          outputMode: outputMode
        )
      }
      let youtubeStart: Task<Void, any Error>
      switch outputDestination.youtubeIngestMode {
      case .dash:
        guard let endpoint = dashResult?.dashEndpoint,
          let boundary = youtubeOutputServiceProcess,
          let sharedH264Service
        else { throw YouTubeClientServiceError.missingDASHDestination }
        let youtubeService = YouTubeOutputWorkspaceService(
          endpoint: endpoint,
          configuration: configuration,
          continuityStore: dashStreamContinuityStore,
          boundary: boundary,
          sharedH264Service: sharedH264Service,
          eventHandler: { self.appendLog($0) },
          failureHandler: youtubeFailureHandler)
        outputCoordinator.installYouTubeService(youtubeService, on: mediaHub)
        youtubeStart = Task {
          try await withCheckedThrowingContinuation { continuation in
            youtubeService.start { continuation.resume(with: $0) }
          }
        }
      case .dualRTMPS:
        guard let rtmpsDestinations else {
          throw YouTubeDualRTMPSConfigurationError.missingDestination
        }
        let rtmpsService = YouTubeRTMPSWorkspaceService(
          destinations: rtmpsDestinations,
          eventHandler: { canvas, event in
            Task { @MainActor in
              youtubeRTMPSLogger.notice(
                "canvas=\(canvas.rawValue, privacy: .public) event=\(event.logDescription, privacy: .public)"
              )
              self.appendLog("YouTube RTMPS \(canvas.rawValue): \(event.logDescription)")
            }
          },
          failureHandler: { error in
            Task { @MainActor in youtubeFailureHandler(error) }
          })
        guard
          outputCoordinator.installYouTubeRTMPSService(
            rtmpsService,
            landscapeHub: mediaHub,
            portraitHub: portraitMediaHub)
        else { throw YouTubeClientServiceError.youtubeRTMPSServiceAlreadyInstalled }
        youtubeStart = Task { try await rtmpsService.waitUntilPublishing() }
      }
      if outputMode.recordsLocally {
        let recordingCustomFields = outputDestination.recordingCustomFields
        let recordAudioTracks = workspaceSideAudioTracks
        let makeRecordService: () throws -> SessionRecordService = {
          try SessionRecordService(
            baseDirectory: self.outputBaseDirectory,
            recordID: SessionRecordService.makeRecordID(),
            writerConfiguration: ProgramOutputEncodingConfiguration.make(
              configuration: configuration),
            portraitWriterConfiguration: ProgramOutputEncodingConfiguration.make(
              configuration: portraitConfiguration ?? configuration),
            audioTracks: recordAudioTracks,
            recordsLandscape: self.outputDestination.recordsLandscape,
            recordsPortrait: self.outputDestination.recordsPortrait,
            customFields: recordingCustomFields,
            diagnosticsContext: self.applicationRouter.recordingDiagnosticsContextIfEnabled(),
            failureHandler: recordFailureHandler)
        }
        let recordService = try makeRecordService()
        outputCoordinator.installRecordService(
          recordService,
          on: mediaHub,
          portraitHub: portraitMediaHub,
          makeNext: makeRecordService,
          enqueueControl: { operation in
            self.eventCoordinator.enqueue { _ in operation() }
          },
          failureHandler: recordFailureHandler,
          eventHandler: { self.appendLog($0) })
        try await startAndWait(recordService: recordService)
        await withCheckedContinuation { continuation in
          outputCoordinator.installRecordInputAudioSubscriptions(
            tracks: recordAudioTracks,
            captureSessionCoordinator: workspaceCaptureSessionCoordinator,
            failureHandler: recordFailureHandler,
            completionHandler: { continuation.resume() })
        }
        appendLog("Recording package started: \(recordService.packageDirectory.path)")
      }
      try await startAndWait(
        session: session,
        programPreferences: programPreferences,
        audioDeviceIDsByInputKey: audioDeviceIDsByInputKey,
        eventHandler: { message in
          self.appendLog(message)
        },
        failureHandler: outputFailureHandler
      )
      try await youtubeStart.value

      guard outputCoordinator.operationID == operationID,
        outputCoordinator.lifecycleState == .starting
      else {
        session.stop()
        await stopAndWait(for: session)
        await finishSessionTasks()
        let serviceStopResult = await outputCoordinator.stopServices()
        if case .failure(let error) = serviceStopResult {
          logOutputServiceStopFailure(error, context: "cancelled startup cleanup")
        }
        return
      }
      outputCoordinator.lifecycleState = .running
      outputCoordinator.activeMode = outputMode
      if outputDestination.youtubeIngestMode == .dualRTMPS {
        let streamIDs: [(YouTubeRTMPSCanvas, String)] = [
          (YouTubeRTMPSCanvas.landscape, transientLandscapeLiveStreamID),
          (YouTubeRTMPSCanvas.portrait, transientPortraitLiveStreamID),
        ].compactMap { canvas, id in
          guard
            let sourceID = streamKeyConfigurations.first(where: { $0.id == id })?.sourceLiveStreamID
          else { return nil }
          return (canvas, sourceID)
        }
        if !streamIDs.isEmpty {
          Task { @MainActor in
            guard
              let token = try? await authState.validAccessToken(
                configuration: oauthClientState.configuration)
            else { return }
            await monitorRTMPSHealth(
              accessToken: token, streamIDs: streamIDs, operationID: operationID)
          }
        }
      }
      outputCoordinator.recordService?.recordOutputStarted()
      await logger.append(.outputStarted)
      RecordingDockStatusController.shared.setStatus(
        outputMode.recordsLocally ? .recording : nil,
        for: recordingDockStatusID)
      appendLog(
        dashResult.map { result in
          result.reusedBoundStream
            ? "Connected YouTube broadcast \(broadcastID ?? "(missing broadcast id)") using an existing bound DASH LiveStream."
            : "Connected YouTube broadcast \(broadcastID ?? "(missing broadcast id)") to a temporary DASH LiveStream."
        } ?? "Connected Default and Vertical YouTube RTMPS LiveStreams."
      )
    } catch {
      guard self.outputCoordinator.operationID == operationID else { return }
      await handleOutputFailure(
        WorkspaceOutputFailure(
          source: .startup,
          error: error,
          operationID: operationID,
          outputMode: outputMode
        ),
        logger: logger)
    }
  }

  private func stopOutputSession() {
    windowMode = .edit
    eventCoordinator.enqueue { logger in
      guard self.outputCoordinator.lifecycleState != .idle else { return }
      await logger.append(.outputStopRequested)
      self.transientSelectedYouTubeBroadcastID = nil
      let operationID = self.outputCoordinator.invalidateOperations(for: .stopping)
      let session = self.outputCoordinator.currentSession
      let outputMode =
        self.outputCoordinator.activeMode ?? self.outputDestination.enabledCaptureOutputMode
        ?? .record
      session?.stop()
      if let session { await self.stopAndWait(for: session) }
      await self.finishSessionTasks()
      let serviceStopResult = await self.outputCoordinator.stopServices()
      await self.outputCoordinator.finishYouTubeOutputServiceProcess()
      guard self.outputCoordinator.operationID == operationID else { return }
      if outputMode.recordsLocally {
        self.localOutputStore.endAccess()
      }
      self.outputCoordinator.resetSession()
      if case .failure(let error) = serviceStopResult {
        self.presentOutputServiceStopFailure(error, context: "stopping output")
        await logger.append(.outputStopped)
        return
      }
      self.outputCoordinator.lifecycleState = .idle
      await logger.append(.outputStopped)
      RecordingDockStatusController.shared.setStatus(nil, for: self.recordingDockStatusID)
      self.appendLog("Output stopped.")
    }
  }

  @discardableResult
  private func startOutputSession() -> Bool {
    guard canStartOutputSession else { return false }
    guard activeOutputProfile != nil else {
      let description =
        "This Workspace uses an unsupported output configuration. Select SDR 1080p60 before starting output."
      appendLog("Output could not start: \(description)")
      outputFailureDescription = description
      return false
    }
    guard canStartProgramAudioMix else {
      let description = programAudioMixValidationFailureDescription
      appendLog("Output could not start: \(description)")
      outputFailureDescription = description
      return false
    }
    if outputDestination.recordsLocally {
      let directory = outputBaseDirectory
      localOutputStore.beginAccess(to: directory)
      do {
        try localOutputStore.validateWritableBaseDirectory(directory)
      } catch {
        localOutputStore.endAccess()
        let description = errorDescription(error)
        appendLog("Output could not start: \(description)")
        outputFailureDescription = description
        return false
      }
      localOutputStore.endAccess()
    }
    guard saveWorkspaceForOutput() != nil else { return false }
    enterOutputMode()
    startLoadedOutputSession()
    return true
  }

  private var programAudioMixValidationFailureDescription: String {
    let landscapeAudioChannels = compositeProgramDefinition.audioChannels
    let portraitAudioChannels = portraitCompositeProgramDefinition.audioChannels
    if landscapeAudioChannels.isEmpty, portraitAudioChannels.isEmpty {
      return
        "Landscape and Portrait Audio Mixes are empty. Configure both mixes before starting output."
    }
    if landscapeAudioChannels.isEmpty {
      return "Landscape Audio Mix is empty. Configure it before starting output."
    }
    if portraitAudioChannels.isEmpty {
      return "Portrait Audio Mix is empty. Configure it before starting output."
    }
    return
      "Landscape or Portrait Audio Mix contains an unmapped input device. Map every input device before starting output."
  }

  private func enterOutputMode() {
    buildOutputPipelines()
    selectedSidebarItem = .output
    windowMode = .output
  }

  private func buildOutputPipelines() {
    for record in programLibrary.records {
      let landscapeRuntime = programRuntime(for: record, role: .landscape)
      landscapeRuntime.updateProgram(programConfiguration(for: record, role: .landscape))
      landscapeRuntime.updateProgramPreferences(programPreferences)
      let portraitRuntime = programRuntime(for: record, role: .portrait)
      portraitRuntime.updateProgram(programConfiguration(for: record, role: .portrait))
      portraitRuntime.updateProgramPreferences(
        persistenceCoordinator.store.preferences.portraitProgramPreferences)
    }
  }

  /// Starts an Output Operation while the same Workspace Window owns both the
  /// persisted document lock and the live session.
  private func startLoadedOutputSession() {
    guard canStartOutputSession else { return }
    shutdownCoordinator.requestStart { _ in
      self.eventCoordinator.enqueue { logger in
        guard self.canBeginOutputSession else { return }
        await logger.append(.outputStartRequested)
        await self.beginOutputSession(logger: logger)
      }
    }
  }

  private func beginOutputSession(logger: EventTaskLogger) async {
    guard activeOutputProfile != nil else {
      appendLog(
        "This Workspace uses a legacy output configuration. Select SDR 1080p60 before starting output."
      )
      outputCoordinator.lifecycleState = .readyToRestart
      return
    }
    if outputCoordinator.lifecycleState != .readyToRestart {
      dashStreamContinuityStore.beginNewOutputSession()
    }
    let operationID = outputCoordinator.beginStarting()
    if outputDestination.streamsToYouTube {
      await startYouTubeOutput(operationID: operationID, logger: logger)
    } else if outputDestination.recordsLocally {
      await startRecording(operationID: operationID, logger: logger)
    } else {
      outputCoordinator.lifecycleState = .idle
      windowMode = .edit
      outputFailureDescription = "Enable Record or YouTube before starting output."
    }
  }

  private func reportOutputFailure(
    _ error: Error,
    source: WorkspaceOutputFailureSource,
    operationID: UUID,
    outputMode: CaptureOutputMode
  ) {
    guard outputCoordinator.operationID == operationID,
      outputCoordinator.lifecycleState == .running
        || outputCoordinator.lifecycleState == .starting
    else { return }
    let failure = WorkspaceOutputFailure(
      source: source,
      error: error,
      operationID: operationID,
      outputMode: outputMode
    )
    eventCoordinator.enqueue { logger in
      await self.handleOutputFailure(failure, logger: logger)
    }
  }

  private func handleOutputFailure(
    _ failure: WorkspaceOutputFailure,
    logger: EventTaskLogger
  ) async {
    guard outputCoordinator.operationID == failure.operationID,
      outputCoordinator.lifecycleState == .running
        || outputCoordinator.lifecycleState == .starting
    else { return }

    await logger.append(.outputFailureHandlingStarted)
    let description = errorDescription(failure.error)
    let nsError = failure.error as NSError
    ldtxAppLogger.error(
      "\(failure.source.rawValue, privacy: .public) failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .public)"
    )
    appendLog("\(failure.source.rawValue) failed; stopping output: \(description)")
    let stopOperationID = outputCoordinator.invalidateOperations(for: .stopping)
    let session = outputCoordinator.currentSession
    session?.stop()
    await stopSessionTasks()
    if let session { await stopAndWait(for: session) }
    let serviceStopResult = await outputCoordinator.stopServicesPreservingIncompleteRecording()
    await outputCoordinator.finishYouTubeOutputServiceProcess()
    guard outputCoordinator.operationID == stopOperationID else { return }
    if failure.outputMode.recordsLocally {
      localOutputStore.endAccess()
    }
    outputCoordinator.resetSession()
    if case .failure(let stopError) = serviceStopResult {
      logOutputServiceStopFailure(stopError, context: "failure cleanup")
    }
    outputCoordinator.lifecycleState = .idle
    RecordingDockStatusController.shared.setStatus(nil, for: recordingDockStatusID)
    outputFailureDescription = description
    await logger.append(.outputStopped)
    await logger.append(.outputFailureHandlingCompleted)
  }

  private func markOutputSessionReadyToRestart(operationID: UUID) {
    guard outputCoordinator.operationID == operationID,
      outputCoordinator.lifecycleState == .starting
    else {
      return
    }
    outputCoordinator.lifecycleState = .readyToRestart
  }

  private func logOutputServiceStopFailure(_ error: Error, context: String) {
    let description = errorDescription(error)
    let nsError = error as NSError
    ldtxAppLogger.error(
      "YouTube finalization failed context=\(context, privacy: .public) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .public)"
    )
    appendLog("YouTube finalization failed while \(context): \(description)")
  }

  private func presentOutputServiceStopFailure(_ error: Error, context: String) {
    logOutputServiceStopFailure(error, context: context)
    outputCoordinator.lifecycleState = .idle
    RecordingDockStatusController.shared.setStatus(nil, for: recordingDockStatusID)
    outputFailureDescription = errorDescription(error)
  }

  private func stopAndWait(for session: ActiveDualProgramOutputSession) async {
    await withCheckedContinuation { continuation in
      session.stop { continuation.resume() }
    }
  }

  private func startAndWait(
    session: ActiveDualProgramOutputSession,
    programPreferences: ProgramPreferences,
    audioDeviceIDsByInputKey: [String: String],
    eventHandler: @escaping @MainActor (String) -> Void,
    failureHandler: @escaping @MainActor (Error) -> Void
  ) async throws {
    try await withCheckedThrowingContinuation { continuation in
      session.start(
        programPreferences: programPreferences,
        audioDeviceIDsByInputKey: audioDeviceIDsByInputKey,
        eventHandler: eventHandler,
        failureHandler: failureHandler,
        completionHandler: { result in continuation.resume(with: result) }
      )
    }
  }

  private func startAndWait(recordService: SessionRecordService) async throws {
    try recordService.start()
  }

  private func pauseOutputSession() {
    guard outputCoordinator.lifecycleState == .running,
      outputCoordinator.currentSession != nil
    else {
      return
    }

    eventCoordinator.enqueue { logger in
      guard self.outputCoordinator.lifecycleState == .running,
        let session = self.outputCoordinator.currentSession
      else { return }
      await logger.append(.outputStopRequested)
      let operationID = self.outputCoordinator.invalidateOperations(for: .pausing)
      let outputMode = self.outputCoordinator.activeMode
      session.stop()
      await self.stopAndWait(for: session)
      await self.finishSessionTasks()
      let serviceStopResult = await self.outputCoordinator.stopServices()
      await self.outputCoordinator.finishYouTubeOutputServiceProcess()
      guard self.outputCoordinator.operationID == operationID,
        self.outputCoordinator.lifecycleState == .pausing
      else {
        return
      }
      if outputMode?.recordsLocally == true {
        self.localOutputStore.endAccess()
      }
      self.outputCoordinator.resetSession()
      if case .failure(let error) = serviceStopResult {
        self.presentOutputServiceStopFailure(error, context: "pausing output")
        await logger.append(.outputStopped)
        return
      }
      self.outputCoordinator.lifecycleState = .readyToRestart
      await logger.append(.outputStopped)
      RecordingDockStatusController.shared.setStatus(
        outputMode?.recordsLocally == true ? .paused : nil,
        for: self.recordingDockStatusID)
      self.appendLog(
        "Output paused. Press Start to begin a new session with the current Output Settings.")
    }
  }

  private func startYouTubeOutput(operationID: UUID, logger: EventTaskLogger) async {
    isLoadingBroadcasts = true
    defer { isLoadingBroadcasts = false }

    do {
      if outputDestination.youtubeIngestMode == .dualRTMPS {
        guard outputCoordinator.operationID == operationID,
          outputCoordinator.lifecycleState == .starting
        else { return }
        await connectYouTube(broadcast: nil, operationID: operationID, logger: logger)
        return
      }

      let broadcasts = try await loadExistingBroadcasts()
      guard outputCoordinator.operationID == operationID,
        outputCoordinator.lifecycleState == .starting
      else {
        return
      }
      existingBroadcasts = broadcasts
      appendLog("Loaded \(broadcasts.count) active/upcoming YouTube broadcast(s).")

      guard let broadcast = preferredExistingBroadcast else {
        appendLog("Create or schedule a YouTube broadcast in Manage before connecting.")
        if outputCoordinator.operationID == operationID {
          outputCoordinator.lifecycleState = .readyToRestart
        }
        return
      }
      await connectYouTube(broadcast: broadcast, operationID: operationID, logger: logger)
    } catch {
      if outputCoordinator.operationID == operationID {
        outputCoordinator.lifecycleState = .readyToRestart
      }
      appendLog("Broadcast list failed: \(errorDescription(error))")
      logError("Broadcast list failed", error: error)
    }
  }

  private func monitorRTMPSHealth(
    accessToken: String,
    streamIDs: [(YouTubeRTMPSCanvas, String)],
    operationID: UUID
  ) async {
    for delay in [Duration.seconds(2), .seconds(3), .seconds(5)] {
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, outputCoordinator.operationID == operationID,
        outputCoordinator.lifecycleState == .running
      else { return }
      for (canvas, streamID) in streamIDs {
        do {
          let status = try await youtubeClientService.liveStreamStatus(
            accessToken: accessToken, id: streamID)
          guard outputCoordinator.operationID == operationID else { return }
          let health = status?.healthStatus?.status ?? "unknown"
          let stream = status?.streamStatus ?? "unknown"
          youtubeRTMPSLogger.info(
            "canvas=\(canvas.rawValue, privacy: .public) stream=\(stream, privacy: .public) health=\(health, privacy: .public)"
          )
          appendLog(
            "YouTube RTMPS \(canvas.rawValue) health: stream=\(stream) health=\(health)")
          for issue in status?.healthStatus?.configurationIssues ?? [] {
            let type = issue.type ?? "unknown"
            let severity = issue.severity ?? "unknown"
            let reason = issue.reason ?? "Unspecified issue"
            youtubeRTMPSLogger.warning(
              "canvas=\(canvas.rawValue, privacy: .public) issueType=\(type, privacy: .public) severity=\(severity, privacy: .public) reason=\(reason, privacy: .public)"
            )
            appendLog(
              "YouTube RTMPS \(canvas.rawValue) issue: type=\(type) severity=\(severity) reason=\(reason)"
            )
          }
        } catch {
          guard outputCoordinator.operationID == operationID else { return }
          logError("YouTube RTMPS health lookup failed", error: error)
        }
      }
    }
  }

  private func broadcastActivityDate(_ broadcast: YouTubeLiveBroadcast) -> Date {
    broadcastDate(from: broadcast.snippet?.actualStartTime)
      ?? broadcastDate(from: broadcast.snippet?.publishedAt)
      ?? .distantPast
  }

  private func broadcastScheduleDate(_ broadcast: YouTubeLiveBroadcast) -> Date {
    broadcastDate(from: broadcast.snippet?.scheduledStartTime)
      ?? broadcastDate(from: broadcast.snippet?.publishedAt)
      ?? .distantFuture
  }

  private func broadcastDate(from value: String?) -> Date? {
    guard let value else {
      return nil
    }
    return ISO8601DateFormatter().date(from: value)
  }

  private var knownYouTubeChannelID: String? {
    if let channelID = normalizedChannelID(authState.channelID) {
      return channelID
    }
    if let channelID = normalizedChannelID(
      existingBroadcasts
        .first { $0.id == transientSelectedYouTubeBroadcastID }?
        .snippet?
        .channelId
    ) {
      return channelID
    }
    return
      existingBroadcasts
      .compactMap { normalizedChannelID($0.snippet?.channelId) }
      .first
  }

  private func youtubeLiveManagementURL(channelID: String?) -> URL? {
    guard let channelID = normalizedChannelID(channelID) else {
      return nil
    }
    return URL(string: "https://studio.youtube.com/channel/\(channelID)/livestreaming")
  }

  private func normalizedChannelID(_ channelID: String?) -> String? {
    guard let trimmed = channelID?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else {
      return nil
    }
    return trimmed
  }

  private func normalizedBroadcastID(_ broadcastID: String?) -> String? {
    guard let trimmed = broadcastID?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty,
      trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    else { return nil }
    return trimmed
  }

  private func startRecording(operationID: UUID, logger: EventTaskLogger) async {
    guard outputDestination.recordsLocally, !outputDestination.streamsToYouTube else {
      appendLog("Select Record before starting local recording.")
      markOutputSessionReadyToRestart(operationID: operationID)
      return
    }
    guard outputCoordinator.lifecycleState == .starting,
      outputCoordinator.operationID == operationID
    else {
      return
    }
    let configuration = activeProgramConfiguration()
    guard !configuration.audioChannels.isEmpty else {
      appendLog("Configure the Landscape Audio Mix before starting output.")
      markOutputSessionReadyToRestart(operationID: operationID)
      return
    }

    do {
      let portraitConfiguration = selectedProgramDefinitionRecord.map {
        programConfiguration(for: $0, role: .portrait)
      }
      selectedProgramRuntime.updateProgram(configuration)
      try await requestRequiredCaptureAccess(
        configurations: [configuration] + (portraitConfiguration.map { [$0] } ?? []))
      guard await synchronizeResourcesAfterRequiredCaptureAccess() else { return }
      guard outputCoordinator.operationID == operationID,
        outputCoordinator.lifecycleState == .starting
      else {
        return
      }
      let mediaHub = ProgramOutputMediaHub()
      let portraitMediaHub = ProgramOutputMediaHub()
      let session = ActiveDualProgramOutputSession(
        landscapeRuntime: selectedProgramRuntime,
        portraitRuntime: selectedPortraitProgramRuntime,
        captureSessionCoordinator: workspaceCaptureSessionCoordinator,
        landscapeMediaHub: mediaHub,
        portraitMediaHub: portraitMediaHub,
        portraitPreferences: persistenceCoordinator.portraitProgramPreferences,
        portraitAudioDeviceIDsByInputKey: portraitConfiguration.map {
          mappedInputAudioDeviceIDs(
            composite: $0.composite,
            audioChannels: $0.audioChannels,
            workspaceInputDevices: programInputDevices,
            inputAudioDeviceMappings: inputAudioDeviceMappings)
        } ?? [:],
        programRuntimeTransitionStateHandler: { [weak outputCoordinator] isTransitioning in
          outputCoordinator?.isProgramRuntimeTransitioning = isTransitioning
        }
      )
      outputCoordinator.currentMediaHub = mediaHub
      outputCoordinator.portraitMediaHub = portraitMediaHub
      outputCoordinator.currentSession = session
      createSessionTaskQueue()
      synchronizeVisionAnalysis()
      localOutputStore.beginAccess(to: outputBaseDirectory)
      let audioDeviceIDsByInputKey = mappedInputAudioDeviceIDs(
        composite: configuration.composite,
        audioChannels: configuration.audioChannels,
        workspaceInputDevices: programInputDevices,
        inputAudioDeviceMappings: inputAudioDeviceMappings
      )
      let outputFailureHandler: @MainActor (Error) -> Void = { error in
        guard self.outputCoordinator.operationID == operationID else { return }
        self.reportOutputFailure(
          error,
          source: .outputSession,
          operationID: operationID,
          outputMode: .record
        )
      }
      let recordFailureHandler: @MainActor (Error) -> Void = { error in
        guard self.outputCoordinator.operationID == operationID else { return }
        self.reportOutputFailure(
          error,
          source: .recording,
          operationID: operationID,
          outputMode: .record
        )
      }
      let recordAudioTracks = workspaceSideAudioTracks
      let recordingCustomFields = outputDestination.recordingCustomFields
      let makeRecordService: () throws -> SessionRecordService = {
        try SessionRecordService(
          baseDirectory: self.outputBaseDirectory,
          recordID: SessionRecordService.makeRecordID(),
          writerConfiguration: ProgramOutputEncodingConfiguration.make(
            configuration: configuration),
          portraitWriterConfiguration: ProgramOutputEncodingConfiguration.make(
            configuration: portraitConfiguration ?? configuration),
          audioTracks: recordAudioTracks,
          recordsLandscape: self.outputDestination.recordsLandscape,
          recordsPortrait: self.outputDestination.recordsPortrait,
          customFields: recordingCustomFields,
          diagnosticsContext: self.applicationRouter.recordingDiagnosticsContextIfEnabled(),
          failureHandler: recordFailureHandler)
      }
      let recordService = try makeRecordService()
      outputCoordinator.installRecordService(
        recordService,
        on: mediaHub,
        portraitHub: portraitMediaHub,
        makeNext: makeRecordService,
        enqueueControl: { operation in
          self.eventCoordinator.enqueue { _ in operation() }
        },
        failureHandler: recordFailureHandler,
        eventHandler: { self.appendLog($0) })
      try await startAndWait(recordService: recordService)
      await withCheckedContinuation { continuation in
        outputCoordinator.installRecordInputAudioSubscriptions(
          tracks: recordAudioTracks,
          captureSessionCoordinator: workspaceCaptureSessionCoordinator,
          failureHandler: recordFailureHandler,
          completionHandler: { continuation.resume() })
      }
      appendLog("Recording package started: \(recordService.packageDirectory.path)")
      try await startAndWait(
        session: session,
        programPreferences: programPreferences,
        audioDeviceIDsByInputKey: audioDeviceIDsByInputKey,
        eventHandler: { message in
          self.appendLog(message)
        },
        failureHandler: outputFailureHandler
      )

      guard outputCoordinator.operationID == operationID,
        outputCoordinator.lifecycleState == .starting
      else {
        session.stop()
        await stopAndWait(for: session)
        await finishSessionTasks()
        let serviceStopResult = await outputCoordinator.stopServices()
        if case .failure(let error) = serviceStopResult {
          logOutputServiceStopFailure(error, context: "cancelled recording startup cleanup")
        }
        return
      }
      outputCoordinator.lifecycleState = .running
      outputCoordinator.activeMode = .record
      outputCoordinator.recordService?.recordOutputStarted()
      await logger.append(.outputStarted)
      RecordingDockStatusController.shared.setStatus(.recording, for: recordingDockStatusID)
      appendLog("Recording started.")
    } catch {
      guard outputCoordinator.operationID == operationID else { return }
      await handleOutputFailure(
        WorkspaceOutputFailure(
          source: .startup,
          error: error,
          operationID: operationID,
          outputMode: .record
        ),
        logger: logger)
    }
  }

  @discardableResult
  private func presentRecordingIDCollisionAlertIfNeeded(_ error: Error) -> Bool {
    guard let serviceError = error as? SessionRecordServiceError,
      case .recordingPackageAlreadyExists(let url) = serviceError
    else {
      return false
    }
    let alert = NSAlert()
    alert.messageText = "Recording Could Not Be Started"
    alert.informativeText =
      "A recording named \(url.lastPathComponent) already exists. Wait until the date and time ID changes, or move the existing recording, then try again."
    alert.alertStyle = .critical
    alert.addButton(withTitle: "OK")
    alert.runModal()
    return true
  }

  private func activeProgramConfiguration() -> ProgramRuntimeConfiguration {
    programConfiguration(
      composite: compositeProgramDefinition,
      programName: selectedProgramDefinitionName,
      audioChannels: compositeProgramDefinition.audioChannels
    )
  }

  private func hasValidAudioDeviceMappings(
    _ configuration: ProgramRuntimeConfiguration
  ) -> Bool {
    let mappings = mappedInputAudioDeviceIDs(
      composite: configuration.composite,
      audioChannels: configuration.audioChannels,
      workspaceInputDevices: programInputDevices,
      inputAudioDeviceMappings: inputAudioDeviceMappings)
    return configuration.audioChannels.allSatisfy { channel in
      guard channel.component.definition.usesInputAudioDevice else { return true }
      let key = configuration.audioChannels.inputAudioDeviceMappingKey(for: channel)
      return mappings[key]?.isEmpty == false
    }
  }

  private func programConfiguration(
    for record: SavedProgramDefinitionRecord,
    role: ProgramCanvasRole = .landscape
  )
    -> ProgramRuntimeConfiguration
  {
    let canvas = record[role]
    let composite = resolvedComposite(
      canvas.composite,
      programName: record.name,
      preferences: persistenceCoordinator.store.preferences.programPreferences(for: role),
      canvasWidth: canvas.canvasWidth,
      canvasHeight: canvas.canvasHeight
    )
    return programConfiguration(
      composite: composite,
      programName: record.name,
      canvasWidth: canvas.canvasWidth,
      canvasHeight: canvas.canvasHeight,
      frameRate: canvas.frameRateNumerator,
      audioChannels: composite.audioChannels,
      outputProfile: role == .landscape
        ? ProgramOutputProfile.sdr1080p60.withVideoBitRate(
          persistenceCoordinator.store.definition.outputConfiguration.videoBitRate)
        : ProgramOutputProfile.sdrPortrait1080p60.withVideoBitRate(
          persistenceCoordinator.store.definition.outputConfiguration.portraitVideoBitRate)
    )
  }

  private func programConfiguration(
    composite: CompositeProgramDefinition,
    programName: String?,
    canvasWidth: Int? = nil,
    canvasHeight: Int? = nil,
    frameRate: Int? = nil,
    audioChannels: [ProgramAudioChannel]? = nil,
    outputProfile: ProgramOutputProfile? = nil
  ) -> ProgramRuntimeConfiguration {
    let resolvedWidth = canvasWidth ?? outputCanvas.canvasSize.width
    let resolvedHeight = canvasHeight ?? outputCanvas.canvasSize.height
    let size = (width: resolvedWidth, height: resolvedHeight)
    let resolvedAudioChannels = audioChannels ?? effectiveWorkspaceAudioChannels
    let cameraIDsByInputKey = mappedInputCameraDeviceIDs(
      composite: composite,
      workspaceInputDevices: programInputDevices,
      inputCameraDeviceMappings: inputCameraDeviceMappings
    )
    return ProgramRuntimeConfiguration(
      composite: composite,
      audioChannels: resolvedAudioChannels,
      outputProfile: outputProfile ?? activeOutputProfile ?? .sdr1080p60,
      canvasWidth: resolvedWidth,
      canvasHeight: resolvedHeight,
      outputWidth: size.width,
      outputHeight: size.height,
      frameRate: max(frameRate ?? outputCanvas.programDefinitionFrameRate, 1),
      timeSeconds: Float(ProcessInfo.processInfo.systemUptime),
      videoPTSMasterCameraID: workspaceVideoPTSMasterCameraID(
        masterInputDeviceID: workspaceVideoPTSMasterInputDeviceID,
        workspaceInputDevices: programInputDevices
      ),
      cameraIDsByInputKey: cameraIDsByInputKey,
      inputDeviceNamesByInputKey: mappedInputCameraDeviceNames(
        composite: composite,
        workspaceInputDevices: programInputDevices
      ),
      cameraInputColorOverrides: inputCameraColorRangeOverrides(
        composite: composite,
        workspaceInputDevices: programInputDevices
      ),
      backgroundRemovalInputKeys: backgroundRemovalInputCameraDeviceKeys(composite: composite),
      videoLayerProgramName: programName ?? "New Program",
    )
  }

  /// Installs the latest protobuf-backed Program projection once for every
  /// Workspace edit. Preview and output only consume this shared state.
  private func updateSelectedProgramRuntime() {
    let landscapeAudio = programInputDevices.resolvedWorkspaceAudioChannels(
      from: compositeProgramDefinition.audioChannels)
    if landscapeAudio != compositeProgramDefinition.audioChannels {
      compositeProgramDefinition.audioChannels = landscapeAudio
    }
    let portraitAudio = programInputDevices.resolvedWorkspaceAudioChannels(
      from: portraitCompositeProgramDefinition.audioChannels)
    if portraitAudio != portraitCompositeProgramDefinition.audioChannels {
      portraitCompositeProgramDefinition.audioChannels = portraitAudio
    }
    selectedProgramRuntime.updateProgram(activeProgramConfiguration())
    let portraitPreferences = persistenceCoordinator.portraitProgramPreferences
    let portraitComposite = resolvedComposite(
      portraitCompositeProgramDefinition,
      programName: selectedProgramDefinitionName ?? "New Program",
      preferences: portraitPreferences,
      canvasWidth: 1_080,
      canvasHeight: 1_920)
    selectedPortraitProgramRuntime.updateProgram(
      programConfiguration(
        composite: portraitComposite,
        programName: selectedProgramDefinitionName,
        canvasWidth: 1_080,
        canvasHeight: 1_920,
        frameRate: 60,
        audioChannels: portraitComposite.audioChannels,
        outputProfile: .sdrPortrait1080p60.withVideoBitRate(
          persistenceCoordinator.store.definition.outputConfiguration.portraitVideoBitRate)))
    selectedPortraitProgramRuntime.updateProgramPreferences(portraitPreferences)
  }

  private var derivedYouTubeStreamResolution: YouTubeLiveStreamResolution {
    switch outputCanvas.canvasSize.height {
    case 0..<360:
      return .p240
    case 360..<480:
      return .p360
    case 480..<720:
      return .p480
    case 720..<1_080:
      return .p720
    case 1_080..<1_440:
      return .p1080
    case 1_440..<2_160:
      return .p1440
    default:
      return .p2160
    }
  }

  private var derivedYouTubeStreamFrameRate: YouTubeLiveStreamFrameRate {
    max(outputCanvas.programDefinitionFrameRate, 1) >= 60 ? .fps60 : .fps30
  }

  private func requestRequiredCaptureAccess(
    configurations: [ProgramRuntimeConfiguration]
  ) async throws {
    if configurations.contains(where: { configuration in
      configuration.composite.steps.contains(where: {
        $0.component.definition.usesInputCameraDevice
      })
    }),
      await requestCaptureAccess(for: .video) == false
    {
      ldtxAppLogger.error("Camera access preflight failed before starting output.")
      throw CameraCaptureServiceError.cameraAccessDenied
    }

    if configurations.contains(where: { configuration in
      configuration.audioChannels.contains(where: {
        $0.component.definition.usesInputAudioDevice
      })
    }),
      await requestCaptureAccess(for: .audio) == false
    {
      ldtxAppLogger.error("Microphone access preflight failed before starting output.")
      throw CameraCaptureServiceError.microphoneAccessDenied
    }
  }

  private var workspaceSideAudioTracks: [SessionRecordAudioTrack] {
    let audioDevices = programInputDevices.filter { $0.kind == .audio }
    return SessionRecordAudioTrack.make(
      deviceIDsByInputKey: Dictionary(
        uniqueKeysWithValues: audioDevices.compactMap { device in
          device.physicalDeviceID.map { (device.id, $0) }
        }),
      deviceNamesByInputKey: Dictionary(
        uniqueKeysWithValues: audioDevices.map { ($0.id, $0.name) }))
  }

  private func requestCaptureAccess(for mediaType: AVMediaType) async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: mediaType) {
    case .authorized:
      return true
    case .notDetermined:
      return await withCheckedContinuation { continuation in
        AVCaptureDevice.requestAccess(for: mediaType) { granted in
          continuation.resume(returning: granted)
        }
      }
    case .denied, .restricted:
      return false
    @unknown default:
      return false
    }
  }

  private func refreshCameras() {
    let result = captureDeviceStore.reload()
    appendLog(
      "Capture device list refreshed: \(result.cameras.count) camera(s), \(result.audioDevices.count) audio device(s)."
    )
    appendCaptureDeviceDetails(cameras: result.cameras, audioDevices: result.audioDevices)
    if let device = result.restoredSelectedAudioDevice {
      appendLog("Stored capture audio selected: \(device.name).")
    } else if result.didSelectFallbackForUnavailableStoredAudio {
      appendLog("Stored capture audio device is unavailable; selected fallback audio.")
    } else if let preferredAudioDevice = result.preferredAudioDevice {
      appendLog("Preferred safe capture audio selected: \(preferredAudioDevice.name).")
    }
    let heldOutputSession = outputCoordinator.currentSession
    heldOutputSession?.beginVideoFrameHold()
    let didScheduleRestart = shutdownCoordinator.requestStart { _ in
      defer { heldOutputSession?.endVideoFrameHold() }
      let failedRestartCameraIDs: Set<String> = await withCheckedContinuation { continuation in
        self.workspaceCaptureSessionCoordinator.restartAllCaptureSessions {
          continuation.resume(returning: $0)
        }
      }
      self.logWorkspaceCaptureSessionFailures(
        failedRestartCameraIDs,
        prefix: "Workspace capture session restart failed for camera(s)"
      )
      await self.synchronizeInputDeviceCapturesAsync()
    }
    if !didScheduleRestart {
      heldOutputSession?.endVideoFrameHold()
    }
  }

  private func synchronizeInputDeviceCaptures() {
    shutdownCoordinator.requestStart { _ in
      await self.synchronizeInputDeviceCapturesAsync()
    }
  }

  private func synchronizeInputDeviceCapturesAsync() async {
    let heldOutputSession = outputCoordinator.currentSession
    heldOutputSession?.beginVideoFrameHold()
    defer { heldOutputSession?.endVideoFrameHold() }
    let failedCameraIDs: Set<String> = await withCheckedContinuation { continuation in
      beginSynchronizeInputDeviceCaptures { continuation.resume(returning: $0) }
    }
    logWorkspaceCaptureSessionFailures(
      failedCameraIDs,
      prefix: "Input device capture could not start for camera(s)"
    )
  }

  private func synchronizeResourcesAfterRequiredCaptureAccess() async -> Bool {
    await shutdownCoordinator.requestStartAndWait { stopToken in
      guard !stopToken.isStopRequested else { return false }
      await self.synchronizeInputDeviceCapturesAsync()
      return !stopToken.isStopRequested
    }
  }

  private func beginSynchronizeInputDeviceCaptures(
    completionHandler: @escaping @Sendable (Set<String>) -> Void
  ) {
    workspaceCaptureSessionCoordinator.synchronizeInputDeviceCaptures(
      inputDevices: programInputDevices,
      availableCameraIDs: availableWorkspaceInputDeviceCameraIDs(),
      canvasWidth: outputCanvas.canvasSize.width,
      canvasHeight: outputCanvas.canvasSize.height,
      frameRate: max(outputCanvas.programDefinitionFrameRate, 1),
      completionHandler: completionHandler
    )
  }

  private func availableWorkspaceInputDeviceCameraIDs() -> Set<String> {
    Set(captureDeviceStore.cameras.map(\.id))
  }

  private func logWorkspaceCaptureSessionFailures(
    _ failedCameraIDs: Set<String>,
    prefix: String
  ) {
    guard !failedCameraIDs.isEmpty else {
      return
    }
    let failedDevices =
      failedCameraIDs
      .sorted()
      .map(CaptureDeviceStore.redactedDeviceID(_:))
      .joined(separator: ", ")
    appendLog("\(prefix): \(failedDevices)")
  }

  private func chooseLocalOutputDirectory() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.directoryURL = outputBaseDirectory
    panel.message = "Choose a folder for local DASH and MP4 output."
    panel.prompt = "Use Folder"

    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return url
  }

  private func applyOutputDestination(_ destination: OutputDestination) {
    outputDestination = destination
    persistWorkspacePreferences()
  }

  private func appendCaptureDeviceDetails(
    cameras: [CameraCaptureSource],
    audioDevices: [AudioCaptureSource]
  ) {
    for camera in cameras {
      appendLog(
        "Camera device: name=\(camera.name), type=\(camera.deviceType), modelID=\(camera.modelID), id=\(CaptureDeviceStore.redactedDeviceID(camera.id)), external=\(camera.isExternal), format=\(camera.formatSummary)"
      )
    }
    for device in audioDevices {
      appendLog(
        "Audio device: name=\(device.name), type=\(device.deviceType), modelID=\(device.modelID), id=\(CaptureDeviceStore.redactedDeviceID(device.id)), external=\(device.isExternal), format=\(device.formatSummary)"
      )
    }
  }

  private func appendLog(_ message: String) {
    logStore.append(message)
  }

  private func errorDescription(_ error: Error) -> String {
    if let captureError = error as? CameraCaptureServiceError {
      switch captureError {
      case .microphoneAccessDenied:
        return
          "\(captureError.localizedDescription) Allow Microphone access for LDTX in System Settings > Privacy & Security > Microphone, then restart the app."
      case .cameraAccessDenied:
        return
          "\(captureError.localizedDescription) Allow Camera access for LDTX in System Settings > Privacy & Security > Camera, then restart the app."
      default:
        return captureError.localizedDescription
      }
    }
    if let youtubeError = error as? YouTubeLiveAPIError,
      let diagnostics = youtubeError.sanitizedDiagnosticSummary
    {
      return "\(youtubeError.localizedDescription) \(diagnostics)"
    }
    return error.localizedDescription
  }

  private func logError(_ prefix: String, error: Error) {
    let nsError = error as NSError
    if let youtubeError = error as? YouTubeLiveAPIError,
      let diagnostics = youtubeError.sanitizedDiagnosticSummary
    {
      ldtxAppLogger.error(
        "\(prefix, privacy: .public) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) \(diagnostics, privacy: .public)"
      )
      return
    }

    ldtxAppLogger.error(
      "\(prefix, privacy: .public) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)"
    )
  }
}

private enum WorkspaceResourceRenameKind {
  case inputDevice
  case videoComponent
  case vision
}

private struct WorkspaceResourceRenameRequest: Identifiable {
  let kind: WorkspaceResourceRenameKind
  let name: String

  var id: String { "\(kind)-\(name)" }

  init?(item: WorkspaceSidebarItem) {
    switch item {
    case .inputDevice(let name):
      kind = .inputDevice
      self.name = name
    case .videoComponent(let name):
      kind = .videoComponent
      self.name = name
    case .vision(let name):
      kind = .vision
      self.name = name
    case .output, .canvas, .videoLayers, .programs: return nil
    }
  }

  var displayName: String {
    switch kind {
    case .inputDevice: "Input Device"
    case .videoComponent: "Video Component"
    case .vision: "Vision"
    }
  }

  var sidebarItem: WorkspaceSidebarItem {
    switch kind {
    case .inputDevice: .inputDevice(name)
    case .videoComponent: .videoComponent(name)
    case .vision: .vision(name)
    }
  }

  func renamedSidebarItem(_ newName: String) -> WorkspaceSidebarItem {
    switch kind {
    case .inputDevice: .inputDevice(newName)
    case .videoComponent: .videoComponent(newName)
    case .vision: .vision(newName)
    }
  }
}

private struct WorkspaceResourceRenameSheet: View {
  let request: WorkspaceResourceRenameRequest
  let rename: (String) -> Void
  let cancel: () -> Void
  @State private var proposedName: String

  init(
    request: WorkspaceResourceRenameRequest,
    rename: @escaping (String) -> Void,
    cancel: @escaping () -> Void
  ) {
    self.request = request
    self.rename = rename
    self.cancel = cancel
    _proposedName = State(initialValue: request.name)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Label("Rename \(request.displayName)", systemImage: "pencil.and.list.clipboard")
        .font(.title2.bold())
      Text(
        "This updates every Workspace reference to \(request.name). The operation is applied atomically."
      )
      .foregroundStyle(.secondary)
      TextField("New Name", text: $proposedName)
        .textFieldStyle(.roundedBorder)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: cancel)
        Button("Rename") { rename(proposedName) }
          .keyboardShortcut(.defaultAction)
          .disabled(proposedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 440)
  }
}

struct WorkspaceActions {
  var saveWorkspace: () -> Void
  var saveWorkspaceAs: () -> Void
  var reloadWorkspace: () -> Void
  var canReloadWorkspace: Bool
}

@MainActor
final class WorkspaceCommandCoordinator: ObservableObject {
  static let shared = WorkspaceCommandCoordinator()

  @Published private(set) var activeActions: WorkspaceActions?
  private var actionsByWorkspaceID: [UUID: WorkspaceActions] = [:]
  private var activeWorkspaceID: UUID?

  func register(workspaceID: UUID, actions: WorkspaceActions) {
    actionsByWorkspaceID[workspaceID] = actions
    if activeWorkspaceID == nil {
      activate(workspaceID: workspaceID)
    } else if activeWorkspaceID == workspaceID {
      activeActions = actions
    }
  }

  func activate(workspaceID: UUID) {
    guard let actions = actionsByWorkspaceID[workspaceID] else { return }
    activeWorkspaceID = workspaceID
    activeActions = actions
  }

  func unregister(workspaceID: UUID) {
    actionsByWorkspaceID[workspaceID] = nil
    guard activeWorkspaceID == workspaceID else { return }
    if let replacement = actionsByWorkspaceID.first {
      activeWorkspaceID = replacement.key
      activeActions = replacement.value
    } else {
      activeWorkspaceID = nil
      activeActions = nil
    }
  }
}

final class WorkspaceWindowCloseCoordinator: NSObject, NSWindowDelegate {
  typealias CloseOperation = @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void
  typealias SaveOperation = @MainActor () -> Bool
  typealias BecomeKeyOperation = @MainActor () -> Void
  typealias AfterCloseOperation = @MainActor @Sendable () -> Void

  private let discardsUnsavedChangesOnClose: Bool

  init(discardsUnsavedChangesOnClose: Bool = LDTXRuntimeMode.discardsUnsavedChangesOnClose) {
    self.discardsUnsavedChangesOnClose = discardsUnsavedChangesOnClose
    super.init()
  }

  var chooseCloseAction: ((NSWindow) -> NSApplication.ModalResponse)?
  private var onClose: CloseOperation?
  private var saveBeforeClose: SaveOperation?
  private var hasUnsavedChanges = false
  private var onBecomeKey: BecomeKeyOperation?
  private weak var observedWindow: NSWindow?
  private var closeIsAllowed = false
  private var closeIsPending = false
  private weak var pendingWindow: NSWindow?

  @MainActor
  func beginInstalling(
    window: NSWindow?,
    hasUnsavedChanges: Bool,
    saveBeforeClose: @escaping SaveOperation,
    onClose: @escaping CloseOperation,
    onBecomeKey: @escaping BecomeKeyOperation
  ) {
    self.onClose = onClose
    self.saveBeforeClose = saveBeforeClose
    self.hasUnsavedChanges = hasUnsavedChanges
    self.onBecomeKey = onBecomeKey
    install(window: window)
  }

  @MainActor
  func install(window: NSWindow?) {
    guard let window else {
      ldtxAppLogger.error("Could not install Workspace window close gate: no key window")
      return
    }
    if observedWindow === window, window.delegate === self { return }
    observedWindow = window
    window.delegate = self
    if window.isKeyWindow { onBecomeKey?() }
    ldtxAppLogger.notice("Installed Workspace window close gate")
  }

  @MainActor
  func windowDidBecomeKey(_ notification: Notification) {
    onBecomeKey?()
  }

  @MainActor
  func updateDocumentEdited(_ isDocumentEdited: Bool) {
    hasUnsavedChanges = isDocumentEdited
    (observedWindow ?? pendingWindow)?.isDocumentEdited = isDocumentEdited
  }

  @MainActor
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    ldtxAppLogger.notice("Workspace window close requested")
    guard !closeIsAllowed else { return true }
    guard !closeIsPending, let onClose else { return false }
    guard confirmDiscardingUnsavedChanges(in: sender) else { return false }
    closeIsPending = true
    sender.orderOut(nil)
    onClose { [weak self, weak sender] in
      guard let self, let sender else { return }
      self.closeIsAllowed = true
      sender.performClose(nil)
    }
    return false
  }

  @MainActor
  @discardableResult
  func closeForReload(afterClose: @escaping AfterCloseOperation) -> Bool {
    guard !closeIsAllowed, !closeIsPending, let onClose,
      let window = observedWindow ?? pendingWindow
    else { return false }
    pendingWindow = nil
    closeIsPending = true
    window.orderOut(nil)
    onClose { [weak self, weak window] in
      guard let self, let window else { return }
      self.closeIsAllowed = true
      window.performClose(nil)
      DispatchQueue.main.async { afterClose() }
    }
    return true
  }

  @MainActor
  func confirmClose() -> Bool {
    guard let window = observedWindow else { return true }
    return confirmDiscardingUnsavedChanges(in: window)
  }

  @MainActor
  private func confirmDiscardingUnsavedChanges(in window: NSWindow) -> Bool {
    guard hasUnsavedChanges, !discardsUnsavedChangesOnClose else { return true }

    let alert = NSAlert()
    alert.messageText = "Do you want to save the changes made to this Workspace?"
    alert.informativeText = "Your changes will be lost if you don’t save them."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Don’t Save")
    alert.addButton(withTitle: "Cancel")

    switch chooseCloseAction?(window) ?? alert.runModal() {
    case .alertFirstButtonReturn:
      guard saveBeforeClose?() == true else { return false }
    case .alertSecondButtonReturn:
      break
    default:
      return false
    }

    return true
  }

}

extension InputPhysicalDeviceOption {
  fileprivate init(camera: CameraCaptureSource) {
    self.init(id: camera.id, name: camera.name, isExternal: camera.isExternal)
  }

  fileprivate init(audioDevice: AudioCaptureSource) {
    self.init(id: audioDevice.id, name: audioDevice.name, isExternal: audioDevice.isExternal)
  }
}

@MainActor
private final class WorkspaceObservationValue<Value> {
  let value: Value
  init(_ value: Value) { self.value = value }
}
