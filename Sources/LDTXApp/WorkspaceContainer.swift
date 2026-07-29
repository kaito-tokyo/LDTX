// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AppKit
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
import OSLog
import SwiftUI
import UniformTypeIdentifiers

private let ldtxAppLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "App"
)

private enum WorkspaceLockOpenError: LocalizedError {
  case cancelled

  var errorDescription: String? {
    "Opening the locked Workspace was cancelled."
  }
}

private enum ActiveOutputSessionRestartReason: Equatable {
  case recordingSplit
  case manualReset

  var stoppingLogMessage: String {
    switch self {
    case .recordingSplit:
      "Recording split is stopping the current output session."
    case .manualReset:
      "Session reset is stopping the current output session."
    }
  }

  var startingLogMessage: String {
    switch self {
    case .recordingSplit:
      "Recording split is starting a new output session."
    case .manualReset:
      "Session reset is starting a new output session."
    }
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

extension UTType {
  static let ldtxWorkspace = UTType(exportedAs: "tokyo.kaito.ldtx.workspace")
}

@MainActor
private final class WorkspaceRuntimeState: ObservableObject {
  let captureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  let programPreferencesState: ProgramPreferencesState
  /// Program Runtimes are shared by the Editor and Output modes for the
  /// lifetime of this Workspace window.
  let programRuntimePool = WorkspaceProgramRuntimePool()

  init() {
    let captureSessionCoordinator = WorkspaceCaptureSessionCoordinator()
    self.captureSessionCoordinator = captureSessionCoordinator
    let programPreferencesState = ProgramPreferencesState()
    self.programPreferencesState = programPreferencesState
  }
}

@MainActor
private final class WorkspaceProgramRuntimePool {
  private(set) var runtimesByProgramName: [String: ProgramRuntime] = [:]
  private var bootstrapRuntime: ProgramRuntime?

  func runtime(named name: String?) -> ProgramRuntime? {
    name.flatMap { runtimesByProgramName[$0] }
  }

  func insert(_ runtime: ProgramRuntime, named name: String) {
    runtimesByProgramName[name] = runtime
  }

  func removeRuntime(named name: String) {
    runtimesByProgramName.removeValue(forKey: name)
  }

  func bootstrapRuntime(using makeRuntime: () -> ProgramRuntime) -> ProgramRuntime {
    if let bootstrapRuntime { return bootstrapRuntime }
    let runtime = makeRuntime()
    bootstrapRuntime = runtime
    return runtime
  }

  func clear() {
    runtimesByProgramName.removeAll()
    bootstrapRuntime = nil
  }
}

struct WorkspaceWindowRuntime: View {
  @Environment(\.dismissWindow) private var dismissWindow
  private let request: WorkspaceEditorWindowRequest
  private let applicationRouter: LDTXApplicationRouter
  @ObservedObject var oauthClientState: OAuthClientState
  @ObservedObject var authState: YouTubeAuthState
  private let youtubeClientService: YouTubeClientService
  private let lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  @StateObject private var runtimeState: WorkspaceRuntimeState
  @State private var windowMode: WorkspaceWindowState.Mode
  @State private var shutdownCoordinator: WorkspaceShutdownCoordinator
  @State private var windowCloseCoordinator = WorkspaceWindowCloseCoordinator()
  @State private var audioCoordinator = WorkspaceAudioCoordinator()
  @State private var eventCoordinator: WorkspaceEventCoordinator
  @State private var outputCoordinator = WorkspaceOutputCoordinator()
  @State private var outputCanvas = OutputCanvasModel()
  @State private var outputDestination = AppOutputSettings()
  @State private var previewSettings = AppPreviewSettings()
  @AppStorage("tokyo.kaito.ldtx.output-settings.v1")
  private var appOutputSettingsData = Data()
  @AppStorage("tokyo.kaito.ldtx.preview-settings.v1")
  private var appPreviewSettingsData = Data()
  @State private var existingBroadcasts: [YouTubeLiveBroadcast] = []
  @State private var compositeProgramDefinition = CompositeProgramDefinition()
  @State private var programInputDevices: [WorkspaceInputDeviceRecord] = []
  @State private var workspaceAudioChannels: [ProgramAudioChannel] = []
  @State private var visions: [WorkspaceVisionDefinition] = []
  @State private var workspaceVideoComponents: [WorkspaceVideoComponentRecord] = []
  @State private var workspaceVideoPTSMasterInputDeviceID: String?
  @State private var sessionTaskQueue: SessionTaskQueue?
  @State private var recordingDockStatusID = UUID()
  private let screenCaptureService = ScreenCaptureService()
  @State private var visionFeature = WorkspaceVisionFeature()
  @State private var programPreferencesStore = ProgramPreferencesStore()
  @State private var inputCameraDeviceMappings: [String: String] = [:]
  @State private var inputAudioDeviceMappings: [String: String] = [:]
  @State private var dashStreamContinuityStore = YouTubeOutputWorkspaceStateStore()
  @State private var inputAudioPassthroughChannelKeys: Set<String> = []
  @State private var isLoadingBroadcasts = false
  @State private var isConnectingBroadcast = false
  @State private var captureDeviceStore = CaptureDeviceStore(service: DefaultCaptureDeviceService())
  @State private var localOutputStore = LocalOutputStore(
    service: DefaultLocalOutputService(fileManager: .default)
  )
  @State private var logStore = LogStore()
  @State private var programLibrary = ProgramLibrary(
    service: InMemoryProgramLibraryService()
  )
  @State private var selectedSidebarItem: WorkspaceSidebarItem? = .streamSettings
  @State private var selectedProgramDefinitionName: String?
  @State private var persistenceCoordinator = WorkspacePersistenceCoordinator()
  @State private var didInitializeWorkspace = false
  @State private var didPersistAppSettingsOnClose = false
  @State private var outputFailureDescription: String?
  @State private var isProgramDefinitionDirty = false
  @State private var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?
  @State private var programAddErrorMessage: String?
  @State private var presentedErrorDialog: ErrorDialogKind?
  @State private var workspaceResourceRenameRequest: WorkspaceResourceRenameRequest?
  @State private var isRenamingWorkspaceResource = false
  @State private var captureFrameFeedback: OutputFrameCaptureFeedback?

  private var workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator {
    runtimeState.captureSessionCoordinator
  }

  /// The Runtime for the Program selected in this Window. Editor previews and
  /// output sessions both consume the same Program-scoped Runtime.
  private var selectedProgramRuntime: ProgramRuntime {
    guard let record = selectedProgramDefinitionRecord else {
      return fallbackProgramRuntime
    }
    return programRuntime(for: record)
  }

  /// A bootstrap renderer is used only before a Workspace has selected a
  /// Program. It is never used for an Editor or Output Program.
  private var fallbackProgramRuntime: ProgramRuntime {
    runtimeState.programRuntimePool.bootstrapRuntime(using: makeProgramRuntime)
  }

  private func makeProgramRuntime() -> ProgramRuntime {
    AppFeatureComposition.makeProgramRuntime(
      captureSessionCoordinator: workspaceCaptureSessionCoordinator,
      programPreferencesState: runtimeState.programPreferencesState,
      lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry
    )
  }

  private func programRuntime(for record: SavedProgramDefinitionRecord) -> ProgramRuntime {
    if let runtime = runtimeState.programRuntimePool.runtime(named: record.name) {
      return runtime
    }
    let runtime = makeProgramRuntime()
    runtimeState.programRuntimePool.insert(runtime, named: record.name)
    return runtime
  }

  init(
    request: WorkspaceEditorWindowRequest,
    applicationRouter: LDTXApplicationRouter,
    oauthClientState: OAuthClientState,
    authState: YouTubeAuthState,
    youtubeClientService: YouTubeClientService,
    lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  ) {
    self.request = request
    self.applicationRouter = applicationRouter
    self.oauthClientState = oauthClientState
    self.authState = authState
    self.youtubeClientService = youtubeClientService
    self.lowFrequencyUpdateRegistry = lowFrequencyUpdateRegistry
    _shutdownCoordinator = State(
      initialValue: WorkspaceShutdownCoordinator(
        logger: applicationRouter.makeEventTaskLogger(queueKind: .workspaceResources)
      ))
    _eventCoordinator = State(
      initialValue: WorkspaceEventCoordinator(
        logger: applicationRouter.makeEventTaskLogger(queueKind: .workspaceEvents)
      ))
    _windowMode = State(initialValue: .edit)
    WorkspaceSceneSequence.reserve(
      window: request.windowSequence,
      unsaved: request.unsavedSequence
    )
    _runtimeState = StateObject(wrappedValue: WorkspaceRuntimeState())
  }

  var body: some View {
    windowContent
      .toolbar {
        ToolbarItem(placement: .navigation) {
          HStack(spacing: 6) {
            Image(systemName: "play.rectangle")
              .accessibilityHidden(true)
            Toggle("Program Output Mode", isOn: workspaceLockBinding)
              .toggleStyle(.switch)
              .labelsHidden()
              .controlSize(.small)
              .accessibilityLabel("Program Output Mode")
              .accessibilityValue(windowMode == .output ? "On" : "Off")
              .accessibilityIdentifier("workspaceOutputModeToggle")
          }
          .fixedSize()
          .help(windowMode == .output ? "Output mode is on." : "Output mode is off.")
        }
      }
      .sheet(item: $workspaceResourceRenameRequest) { request in
        WorkspaceResourceRenameSheet(
          request: request,
          rename: performWorkspaceResourceRename,
          cancel: { workspaceResourceRenameRequest = nil }
        )
      }
      .background(
        WorkspaceWindowReader { window in
          WorkspaceCommandCoordinator.shared.register(
            workspaceID: request.windowSequence,
            actions: workspaceActions)
          windowCloseCoordinator.beginInstalling(
            window: window,
            onClose: stopWorkspace,
            onBecomeKey: {
              WorkspaceCommandCoordinator.shared.activate(
                workspaceID: request.windowSequence)
            })
          windowCloseCoordinator.updateDocumentEdited(hasUnsavedWorkspaceChanges)
        }
      )
      .modifier(workspaceDocumentLifecycle)
      .modifier(programRuntimeObservation)
      .onDisappear {
        RecordingDockStatusController.shared.setStatus(nil, for: recordingDockStatusID)
        WorkspaceCommandCoordinator.shared.unregister(workspaceID: request.windowSequence)
        stopWorkspace()
      }
      .onChange(of: visions) { _, _ in
        syncWorkspaceFromCurrentProgramLibrary()
        synchronizeVisionFeature()
        updateWorkspaceWindowDirtyState()
      }
      .onChange(of: workspaceVideoComponents) { _, _ in
        applyWorkspaceVideoComponentsToSelectedProgram()
        syncWorkspaceFromCurrentProgramLibrary()
        updateWorkspaceWindowDirtyState()
      }
      .onChange(of: workspaceVideoPTSMasterInputDeviceID) { _, _ in
        syncWorkspaceFromCurrentProgramLibrary()
        updateSelectedProgramRuntime()
        updateWorkspaceWindowDirtyState()
      }
  }

  @ViewBuilder
  private var windowContent: some View {
    OutputSessionFailureAlert(
      content: workspaceView,
      errorDescription: $outputFailureDescription
    )
  }

  private var windowModeBinding: Binding<WorkspaceWindowState.Mode> {
    Binding(
      get: { windowMode },
      set: { requestedMode in
        switch requestedMode {
        case .edit:
          guard outputSessionControlState == .idle else { return }
          windowMode = .edit
        case .output:
          guard saveWorkspaceForOutput() != nil else { return }
          enterOutputMode()
        }
      }
    )
  }

  private var workspaceLockBinding: Binding<Bool> {
    Binding(
      get: { windowMode == .output },
      set: { isLocked in
        windowModeBinding.wrappedValue = isLocked ? .output : .edit
      }
    )
  }

  private var outputSessionStatus: String {
    switch outputSessionControlState {
    case .idle: "Stopped"
    case .starting: "Starting"
    case .running: "Running"
    case .pausing: "Pausing"
    case .readyToRestart: "Paused"
    case .stopping: "Stopping"
    }
  }

  private var outputSessionSymbol: String {
    switch outputSessionControlState {
    case .running: "record.circle.fill"
    case .readyToRestart: "pause.circle.fill"
    case .starting, .pausing, .stopping: "arrow.triangle.2.circlepath"
    case .idle: "stop.circle"
    }
  }

  private var workspaceView: some View {
    LDTXAppUI.WorkspaceView(
      selectedSidebarItem: $selectedSidebarItem,
      selectedProgramDefinitionName: $selectedProgramDefinitionName,
      workspaceInputDevices: programInputDevicesBinding,
      workspaceAudioChannels: $workspaceAudioChannels,
      visions: visionsBinding,
      videoComponents: $workspaceVideoComponents,
      videoPTSMasterInputDeviceID: videoPTSMasterInputDeviceBinding,
      compositeProgramDefinition: $compositeProgramDefinition,
      programPreferences: programPreferencesBinding,
      saveProgramDefinitionCommand: $saveProgramDefinitionCommand,
      programAddErrorMessage: $programAddErrorMessage,
      presentedErrorDialog: $presentedErrorDialog,
      captureFrameFeedback: $captureFrameFeedback,
      requestWorkspaceResourceRename: requestWorkspaceResourceRename,
      isWorkspaceResourceRenameInProgress: isRenamingWorkspaceResource,
      windowState: WorkspaceWindowState(
        mode: windowMode,
        outputSessionState: outputSessionControlState,
        activeOutputMode: outputCoordinator.activeMode,
        isRecordFinalizing: outputCoordinator.isRecordFinalizing,
        isProgramRuntimeTransitioning: outputCoordinator.isProgramRuntimeTransitioning,
        isOperationLocked: eventCoordinator.isLocked
      ),
      outputCanvas: outputCanvas,
      outputDestination: outputDestination,
      previewSettings: $previewSettings,
      visionRuntimePresenter: visionFeature.presenter,
      backgroundRemovalPreprocessorFactory: AppFeatureComposition
        .backgroundRemovalPreprocessorFactory,
      workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
      lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
      selectedProgramRuntime: selectedProgramRuntime,
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
      isLoadingBroadcasts: isLoadingBroadcasts,
      isGlobalOutputSessionStartEnabled: isGlobalOutputSessionStartEnabled,
      globalOutputSessionStartAccessibilityLabel: globalOutputSessionStartAccessibilityLabel,
      isWorkspaceSaveToolbarEnabled: isWorkspaceSaveToolbarEnabled,
      updateProgramAudioGains: updateProgramAudioGains(preferences:),
      reloadSavedProgramDefinitions: reloadSavedProgramDefinitions,
      refreshCameras: refreshCameras,
      deleteWorkspaceInputDevice: deleteWorkspaceInputDevice(id:),
      deleteWorkspaceVideoComponent: deleteWorkspaceVideoComponent(id:),
      deleteWorkspaceVision: deleteWorkspaceVision(id:),
      saveProgramDefinitionRecord: saveProgramDefinitionRecord(_:),
      programDefinitionDirtyChanged: { isDirty in
        isProgramDefinitionDirty = isDirty
        updateWorkspaceWindowDirtyState()
      },
      stopOutputSession: stopOutputSession,
      startOutputSession: windowMode == .output
        ? startLoadedOutputSession
        : { _ = startOutputSession() },
      pauseOutputSession: pauseOutputSession,
      resetSession: resetSession,
      addProgramDefinition: addProgramDefinition(named:),
      renameProgramDefinition: renameProgramDefinition(oldName:to:),
      deleteProgramDefinition: deleteProgramDefinition(named:),
      moveProgramDefinition: moveProgramDefinition(named:by:),
      saveWorkspace: saveWorkspace,
      refreshExistingBroadcasts: refreshExistingBroadcasts,
      manageYouTubeBroadcasts: manageYouTubeBroadcasts,
      chooseOutputDirectory: chooseLocalOutputDirectory,
      applyOutputSettings: applyOutputSettings(from:),
      analyzeVision: analyzeVision,
      captureFrame: captureOutputFrame,
      openScreenshotsDirectory: openScreenshotsDirectory,
      verifyRecording: verifyRecordingShield,
      featureAvailability: workspaceFeatureAvailability
    )
  }

  private var workspaceFeatureAvailability: WorkspaceFeatureAvailability {
    AppFeatureComposition.workspaceFeatureAvailability
  }

  private func captureOutputFrame() {
    guard !outputCoordinator.isProgramRuntimeTransitioning else {
      captureFrameFeedback = OutputFrameCaptureFeedback(
        message: "Wait for the Program switch to complete before capturing Screenshot(s).",
        isError: true)
      return
    }
    guard let recordingPackageDirectory = activeRecordingPackageDirectory else {
      captureFrameFeedback = OutputFrameCaptureFeedback(
        message: "Start recording before capturing Screenshot(s).",
        isError: true)
      return
    }

    let capturedAt = screenCaptureService.captureDate()
    var sources: [ScreenCaptureSource] = []
    var unavailableSourceNames: [String] = []

    do {
      if let pixelBuffer = selectedProgramRuntime.latestFrame()?.pixelBuffer {
        sources.append(
          try screenCaptureService.snapshot(
            pixelBuffer: pixelBuffer,
            name: "Active Program"))
      } else {
        unavailableSourceNames.append(selectedProgramDefinitionName ?? "Program")
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
        defer { finish() }
        guard !stopToken.isStopRequested else { return }

        do {
          let result = try captureService.captureSet(
            sources: capturedSources,
            capturedAt: capturedAt,
            recordingPackageDirectory: recordingPackageDirectory)
          Task { @MainActor in
            captureFrameFeedback = OutputFrameCaptureFeedback(
              message:
                "Saved \(result.capturedAt.formatted(date: .omitted, time: .standard)) Screenshot(s)\(skippedDescription)",
              isError: false)
            appendLog(
              "Captured \(result.outputURLs.count) output frames: \(result.directory.path)")
          }
        } catch {
          let description = error.localizedDescription
          Task { @MainActor in
            captureFrameFeedback = OutputFrameCaptureFeedback(
              message: description,
              isError: true)
            appendLog("Output frame capture failed: \(description)")
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
    panel.allowedContentTypes = [UTType(filenameExtension: RecordingPackage.pathExtension) ?? .directory]
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
    captureFrameFeedback = OutputFrameCaptureFeedback(message: message, isError: result.status != .valid)
    appendLog("Recording Shield verification: \(result.status.rawValue), package=\(packageURL.lastPathComponent)")
  }

  private var activeRecordingPackageDirectory: URL? {
    guard isRecording else { return nil }
    return outputCoordinator.recordService?.packageDirectory
  }

  private func performStartupTasks() {
    guard !didInitializeWorkspace else { return }
    didInitializeWorkspace = true
    restoreAppOutputSettings()
    restoreAppPreviewSettings()
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
          dismissWindow(id: "workspace-editor", value: request)
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

  private var workspaceDocumentLifecycle: WorkspaceDocumentLifecycle {
    WorkspaceDocumentLifecycle(
      selectedProgramName: selectedProgramDefinitionRecord?.name,
      isWorkspaceDirty: persistenceCoordinator.store.isDirty,
      performStartupTasks: performStartupTasks,
      updateWorkspaceWindowDirtyState: updateWorkspaceWindowDirtyState
    )
  }

  private var programRuntimeObservation: ProgramRuntimeObservation {
    ProgramRuntimeObservation(
      programPreferencesRevision: programPreferencesStore.revision,
      compositeProgramDefinition: compositeProgramDefinition,
      workspaceAudioChannels: workspaceAudioChannels,
      outputCanvasState: outputCanvas.state,
      inputAudioDeviceMappings: inputAudioDeviceMappings,
      workspaceInputDevices: programInputDevices,
      programPreferencesRevisionChanged: distributeProgramPreferences,
      programDefinitionChanged: programDefinitionChanged,
      workspaceAudioChannelsChanged: workspaceAudioChannelsChanged,
      outputCanvasChanged: outputCanvasChanged,
      audioDeviceMappingChanged: { _ = restartAudioMonitor() },
      workspaceInputDevicesChanged: workspaceInputDevicesChanged
    )
  }

  private func stopWorkspace(completion: @escaping @MainActor @Sendable () -> Void = {}) {
    persistAppSettingsOnWorkspaceClose()
    visionFeature.stop()
    runtimeState.programRuntimePool.clear()
    stopWorkspaceResources {
      completion()
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
            await outputCoordinator.stopRecordService()
            await logger.append(.sessionTasksFinalized)
            completion()
          }
        }
      })
  }

  private func finishSessionTasks() async {
    visionFeature.stop()
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
    visionFeature.stop()
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
        await eventCoordinator.interrupt()
        let (operationID, session, outputMode) = await MainActor.run {
          (
            outputCoordinator.invalidateOperations(for: .stopping),
            outputCoordinator.currentSession,
            outputCoordinator.activeMode ?? outputDestination.enabledCaptureOutputMode ?? .record
          )
        }
        if let session { await stopAndWait(for: session) }
        await finishSessionTasks()
        let serviceStopResult = await outputCoordinator.stopServices()
        await outputCoordinator.finishYouTubeOutputServiceProcess()
        await audioCoordinator.stopAndReset()
        await withCheckedContinuation { continuation in
          captureCoordinator.stopAndReset { continuation.resume() }
        }
        await MainActor.run {
          if case .failure(let error) = serviceStopResult {
            logOutputServiceStopFailure(error, context: "workspace shutdown")
          }
          guard outputCoordinator.operationID == operationID else { return }
          if outputMode.recordsLocally {
            localOutputStore.endAccess()
          }
          outputCoordinator.resetSession()
          outputCoordinator.lifecycleState = .idle
        }
      },
      verifyStopped: {
        let audioStopped = audioCoordinator.isFullyStopped()
        let captureStopped = captureCoordinator.isFullyStopped()
        let outputStopped = await MainActor.run { outputCoordinator.isFullyStopped() }
        return audioStopped && captureStopped && outputStopped
      },
      completion: {
        persistenceCoordinator.releaseActiveLock()
        completion()
      }
    )
    if !didBegin, shutdownCoordinator.resourcesAreFullyStopped() {
      completion()
    }
  }

  private func replaceProgramPreferences(with preferences: ProgramPreferences) {
    programPreferencesStore.replace(with: preferences)
  }

  private func distributeProgramPreferences() {
    let current = programPreferencesStore.value
    selectedProgramRuntime.updateProgramPreferences(current)
    outputCoordinator.currentSession?.updateProgramPreferences(current)
    persistWorkspacePreferences()
    updateProgramAudioGains(preferences: current)
  }

  private var programPreferences: ProgramPreferences {
    programPreferencesStore.value
  }

  private var programPreferencesBinding: Binding<ProgramPreferences> {
    Binding(
      get: { programPreferencesStore.value },
      set: { replaceProgramPreferences(with: $0) }
    )
  }

  private func programDefinitionChanged() {
    updateProgramAudioGains(preferences: programPreferences)
    updateSelectedProgramRuntime()
    restartAudioMonitor()
  }

  private func outputCanvasChanged() {
    syncWorkspaceFromCurrentProgramLibrary()
    updateSelectedProgramRuntime()
    synchronizeInputDeviceCaptures()
    updateWorkspaceWindowDirtyState()
  }

  private func workspaceAudioChannelsChanged() {
    syncWorkspaceFromCurrentProgramLibrary()
    updateProgramAudioGains(preferences: programPreferences)
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
      saveWorkspaceAs: { _ = saveWorkspaceAs() }
    )
  }

  private var activeProgramSelectionBinding: Binding<String?> {
    Binding(
      get: { selectedProgramDefinitionName },
      set: { selectedName in
        selectProgramDefinition(named: selectedName, clearsDetailSelection: false)
      }
    )
  }

  private var inputAudioPassthroughChannelKeysBinding: Binding<Set<String>> {
    Binding(
      get: { inputAudioPassthroughChannelKeys },
      set: { channelKeys in
        inputAudioPassthroughChannelKeys = channelKeys
        persistWorkspacePreferences()
        restartAudioMonitor()
      }
    )
  }

  /// PTS selection is part of the rendering pipeline contract. It is frozen
  /// before Output mode builds the Program Runtime pool.
  private var videoPTSMasterInputDeviceBinding: Binding<String?> {
    Binding(
      get: { workspaceVideoPTSMasterInputDeviceID },
      set: { masterInputDeviceID in
        guard windowMode == .edit, !eventCoordinator.isLocked else { return }
        workspaceVideoPTSMasterInputDeviceID = masterInputDeviceID
      }
    )
  }

  private var hasUnsavedWorkspaceChanges: Bool {
    persistenceCoordinator.store.isDirty || isProgramDefinitionDirty
  }

  private var programInputDevicesBinding: Binding<[WorkspaceInputDeviceRecord]> {
    Binding(
      get: { programInputDevices },
      set: { newValue in
        if let (oldName, newName) = inputDeviceRename(from: programInputDevices, to: newValue) {
          performInputDeviceRename(from: oldName, to: newName)
          return
        }
        programInputDevices = newValue
        syncWorkspaceFromCurrentProgramLibrary()
        persistWorkspacePreferences()
        synchronizeInputDeviceCaptures()
        restartAudioMonitor()
      }
    )
  }

  private var visionsBinding: Binding<[WorkspaceVisionDefinition]> {
    Binding(
      get: { visions },
      set: { newValue in
        if let (oldName, newName) = visionRename(from: visions, to: newValue) {
          performVisionRename(from: oldName, to: newName)
        } else {
          visions = newValue
        }
      }
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
    isRenamingWorkspaceResource = true
    defer { isRenamingWorkspaceResource = false }
    guard
      replaceWorkspaceForRename(
        at: workspaceURL,
        mutation: { definition, preferences in
          try definition.renameInputDevice(from: oldName, to: newName, preferences: &preferences)
        })
    else { return }
    if selectedSidebarItem == .inputDevice(oldName) {
      selectedSidebarItem = .inputDevice(newName)
    }
  }

  private func performVisionRename(from oldName: String, to newName: String) {
    guard let workspaceURL = ensureWorkspaceSavedForRename() else { return }
    isRenamingWorkspaceResource = true
    defer { isRenamingWorkspaceResource = false }
    guard
      replaceWorkspaceForRename(
        at: workspaceURL,
        mutation: { definition, _ in
          try definition.renameVision(from: oldName, to: newName)
        })
    else { return }
    if selectedSidebarItem == .vision(oldName) {
      selectedSidebarItem = .vision(newName)
    }
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

    guard
      replaceWorkspaceForRename(
        at: workspaceURL,
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
    if selectedSidebarItem == request.sidebarItem {
      selectedSidebarItem = request.renamedSidebarItem(newName)
    }
    workspaceResourceRenameRequest = nil
  }

  /// Applies a Workspace-wide rename to a complete persisted snapshot. The
  /// UI and runtime are not mutated until the complete Definition and
  /// Preferences have been written successfully, then reloaded as a unit.
  @discardableResult
  private func replaceWorkspaceForRename(
    at workspaceURL: URL,
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
      guard reloadWorkspaceAfterRename(at: workspaceURL) else { return false }
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

  private func initializeNewWorkspace() {
    do {
      let store = try WorkspaceStore(clean: WorkspaceDefinition())
      try replaceWorkspaceStore(store, url: nil, clearsDetailSelection: false)
      appendLog("Created an unsaved Workspace.")
    } catch {
      appendLog("Workspace could not be initialized: \(error.localizedDescription)")
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
  private func reloadWorkspaceAfterRename(at url: URL) -> Bool {
    do {
      let store = try persistenceCoordinator.load(at: url)
      try replaceWorkspaceStore(store, url: url)
      appendLog("Reopened Workspace after rename: \(url.path)")
      return true
    } catch {
      appendLog("Workspace could not be reopened after rename: \(error.localizedDescription)")
      return false
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
      syncWorkspaceFromCurrentProgramLibrary()
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

  private func syncWorkspaceFromCurrentProgramLibrary() {
    let workspaceName =
      persistenceCoordinator.url?.deletingPathExtension().lastPathComponent
      ?? persistenceCoordinator.store.definition.name
    persistenceCoordinator.store.edit { definition in
      definition.name = workspaceName
      definition.programs = programLibrary.records
      definition.inputDevices = programInputDevices.map { device in
        var definitionDevice = device
        definitionDevice.physicalDeviceID = nil
        return definitionDevice
      }
      definition.audioChannels = workspaceAudioChannels
      definition.visions = visions
      definition.videoComponents = workspaceVideoComponents
      definition.outputConfiguration = WorkspaceOutputConfiguration(
        profileID: outputCanvas.canvasSize.width == ProgramOutputProfile.sdr1080p60.width
          && outputCanvas.canvasSize.height == ProgramOutputProfile.sdr1080p60.height
          && outputCanvas.programDefinitionFrameRate == ProgramOutputProfile.sdr1080p60.frameRate
          ? .sdr1080p60 : nil,
        canvasWidth: outputCanvas.canvasSize.width,
        canvasHeight: outputCanvas.canvasSize.height,
        frameRate: outputCanvas.programDefinitionFrameRate,
        videoPTSMasterInputDeviceID: workspaceVideoPTSMasterInputDeviceID
      )
    }
  }

  private func replaceWorkspaceStore(
    _ store: WorkspaceStore,
    url: URL?,
    clearsDetailSelection: Bool = true
  ) throws {
    runtimeState.programRuntimePool.clear()
    persistenceCoordinator.replace(store: store, url: url)
    workspaceAudioChannels = store.definition.audioChannels
    programInputDevices = store.definition.inputDevices.map { device in
      var runtimeDevice = device
      runtimeDevice.physicalDeviceID = store.preferences.physicalDeviceIDsByInputDeviceID[device.id]
      return runtimeDevice
    }
    inputCameraDeviceMappings = store.preferences.inputCameraDeviceMappings
    inputAudioDeviceMappings = store.preferences.inputAudioDeviceMappings
    inputAudioPassthroughChannelKeys = store.preferences.inputAudioMonitorChannelKeys
    visions = store.definition.visions
    workspaceVideoComponents = store.definition.videoComponents
    outputCanvas.canvasSize = OutputCanvasModel.CanvasSize(
      width: store.definition.outputConfiguration.canvasWidth,
      height: store.definition.outputConfiguration.canvasHeight
    )
    outputCanvas.programDefinitionFrameRate = store.definition.outputConfiguration.frameRate
    workspaceVideoPTSMasterInputDeviceID =
      store.definition.outputConfiguration.videoPTSMasterInputDeviceID
    synchronizeVisionFeature()
    isProgramDefinitionDirty = false
    updateWorkspaceWindowDirtyState()
    let selectedName =
      store.preferences.selectedProgramName ?? store.definition.programs.first?.name
    try programLibrary.replaceRecords(store.definition.programs, selectedName: selectedName)
    programPreferencesStore.replace(with: store.preferences.programPreferences)
    let selectedRecord = try programLibrary.ensureDefaultProgram()
    syncWorkspaceFromCurrentProgramLibrary()
    selectProgramDefinition(
      named: selectedRecord.name, clearsDetailSelection: clearsDetailSelection)
    applyWorkspaceVideoComponentsToSelectedProgram()
    synchronizeInputDeviceCaptures()
  }

  private func applyWorkspaceVideoComponentsToSelectedProgram() {
    guard let selectedProgramDefinitionName else { return }
    compositeProgramDefinition = resolvedComposite(
      compositeProgramDefinition,
      programName: selectedProgramDefinitionName
    )
  }

  private func resolvedComposite(
    _ composite: CompositeProgramDefinition,
    programName: String
  ) -> CompositeProgramDefinition {
    WorkspaceVideoComponentResolver.applying(
      workspaceVideoComponents,
      layers: programPreferences.videoLayers(forProgramNamed: programName),
      to: composite
    )
  }

  private func updateWorkspaceWindowDirtyState() {
    windowCloseCoordinator.updateDocumentEdited(hasUnsavedWorkspaceChanges)
  }

  private func saveCurrentProgramDefinitionIfNeeded() {
    guard isProgramDefinitionDirty,
      saveProgramDefinitionCommand?.isEnabled == true
    else {
      return
    }
    saveProgramDefinitionCommand?.perform()
  }

  private var isWorkspaceSaveToolbarEnabled: Bool {
    hasUnsavedWorkspaceChanges || persistenceCoordinator.url == nil
  }

  private var outputBaseDirectory: URL {
    outputDestination.recording.baseDirectoryURL ?? localOutputStore.defaultBaseDirectory
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
      && activeOutputProfile != nil
  }

  private var activeOutputProfile: ProgramOutputProfile? {
    let output = persistenceCoordinator.store.definition.outputConfiguration
    guard output.isSupportedOutputProfile else { return nil }
    return .sdr1080p60
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
    guard let selectedExistingBroadcastID = outputDestination.youtube.existingBroadcastID else {
      return nil
    }
    return existingBroadcasts.first { $0.id == selectedExistingBroadcastID }
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
    guard canStartProgramAudioMix else {
      return false
    }

    return outputDestination.recording.isEnabled || outputDestination.youtube.isEnabled
  }

  private var canCreateLiveStream: Bool {
    if isLoadingBroadcasts || isConnectingBroadcast {
      return false
    }
    if isOutputSessionRunning {
      return false
    }
    return outputDestination.youtube.isEnabled
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
    if !canStartProgramAudioMix {
      return "Configure and map a Workspace audio channel before starting output."
    }
    if outputDestination.youtube.isEnabled,
      preferredExistingBroadcast == nil
    {
      return "Create or schedule a YouTube broadcast in Manage before connecting."
    }

    switch outputDestination.enabledCaptureOutputMode {
    case .none:
      return "Enable Record or YouTube in Output Settings."
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
    let audioChannels = effectiveWorkspaceAudioChannels
    guard !audioChannels.isEmpty else {
      return false
    }

    let mappings = mappedInputAudioDeviceIDs(
      composite: compositeProgramDefinition,
      audioChannels: audioChannels,
      workspaceInputDevices: programInputDevices,
      inputAudioDeviceMappings: inputAudioDeviceMappings
    )
    for channel in audioChannels
    where channel.component.definition.usesInputAudioDevice {
      let key = audioChannels.inputAudioDeviceMappingKey(for: channel)
      guard mappings[key]?.isEmpty == false else {
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
    reloadProgramPreferences()
  }

  private func reloadSavedProgramDefinitions() {
    do {
      try programLibrary.reload()
      let selectedRecord = try programLibrary.ensureDefaultProgram()
      syncWorkspaceFromCurrentProgramLibrary()
      selectProgramDefinition(named: selectedRecord.name, clearsDetailSelection: false)
    } catch {
      programLibrary.resetAfterRestoreFailure()
      appendLog("Stored program definitions could not be restored and were reset.")
      addProgramDefinition()
    }
  }

  private func reloadProgramPreferences() {
    programPreferencesStore.replace(
      with: persistenceCoordinator.store.preferences.programPreferences)
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
        outputCoordinator.currentSession?.switchProgramRuntime(to: selectedProgramRuntime) != false
      else {
        return false
      }
    }
    return true
  }

  private func clearDetailSelection() {
    selectedSidebarItem = .streamSettings
  }

  private func restoreAppOutputSettings() {
    guard !appOutputSettingsData.isEmpty else { return }
    guard
      let output = try? AppOutputSettingsPersistenceCodec.decode(
        from: appOutputSettingsData
      )
    else {
      appendLog("App Output Settings could not be decoded; using defaults.")
      return
    }
    outputDestination = output
  }

  private func persistOutputSettings() {
    do {
      appOutputSettingsData = try AppOutputSettingsPersistenceCodec.encode(outputDestination)
    } catch {
      appendLog("App Output Settings could not be saved: \(error.localizedDescription)")
    }
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

  private func persistAppSettingsOnWorkspaceClose() {
    guard !didPersistAppSettingsOnClose else { return }
    didPersistAppSettingsOnClose = true
    persistOutputSettings()
    persistPreviewSettings()
  }

  private func persistWorkspacePreferences() {
    syncWorkspaceFromCurrentProgramLibrary()
    persistenceCoordinator.store.editPreferences { preferences in
      preferences.programPreferences = programPreferencesStore.value
      var physicalDeviceIDsByInputDeviceID: [String: String] = [:]
      for device in programInputDevices {
        guard let physicalDeviceID = device.physicalDeviceID,
          !physicalDeviceID.isEmpty,
          physicalDeviceIDsByInputDeviceID[device.id] == nil
        else {
          continue
        }
        physicalDeviceIDsByInputDeviceID[device.id] = physicalDeviceID
      }
      preferences.physicalDeviceIDsByInputDeviceID = physicalDeviceIDsByInputDeviceID
      preferences.inputCameraDeviceMappings = inputCameraDeviceMappings
      preferences.inputAudioDeviceMappings = inputAudioDeviceMappings
      preferences.inputAudioMonitorChannelKeys = inputAudioPassthroughChannelKeys
      preferences.selectedProgramName = selectedProgramDefinitionName
    }
    do {
      guard let workspaceURL = persistenceCoordinator.url else { return }
      try persistenceCoordinator.save(persistenceCoordinator.store, to: workspaceURL)
      persistenceCoordinator.replace(store: persistenceCoordinator.store, url: workspaceURL)
      updateWorkspaceWindowDirtyState()
    } catch {
      appendLog("Workspace could not be saved: \(error.localizedDescription)")
    }
  }

  private func saveProgramDefinitionRecord(_ record: SavedProgramDefinitionRecord) -> Bool {
    do {
      try programLibrary.save(record)
      syncWorkspaceFromCurrentProgramLibrary()
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
      syncWorkspaceFromCurrentProgramLibrary()
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
      syncWorkspaceFromCurrentProgramLibrary()
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
      runtimeState.programRuntimePool.removeRuntime(named: name)
      syncWorkspaceFromCurrentProgramLibrary()
      persistWorkspacePreferences()
    } catch {
      appendLog("Program definitions could not be saved: \(error.localizedDescription)")
    }
  }

  private func moveProgramDefinition(named name: String, by offset: Int) {
    guard windowMode == .edit, !eventCoordinator.isLocked else { return }
    do {
      guard try programLibrary.move(named: name, by: offset) else { return }
      syncWorkspaceFromCurrentProgramLibrary()
      persistWorkspacePreferences()
    } catch {
      appendLog("Program definitions could not be reordered: \(error.localizedDescription)")
    }
  }

  private func deleteWorkspaceInputDevice(id: String) {
    guard windowMode == .edit, !eventCoordinator.isLocked else { return }
    saveCurrentProgramDefinitionIfNeeded()
    guard
      mutateWorkspaceDefinition(
        { definition in
          definition.removeInputDevice(named: id)
        },
        updatePreferences: { preferences in
          preferences.removeInputDevice(named: id)
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
    selectedSidebarItem = .streamSettings
    persistWorkspacePreferences()
  }

  @discardableResult
  private func mutateWorkspaceDefinition(
    _ mutation: (inout WorkspaceDefinition) -> Bool,
    updatePreferences: (inout WorkspacePreferences) -> Void = { _ in }
  ) -> Bool {
    syncWorkspaceFromCurrentProgramLibrary()
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
    persistenceCoordinator.store.editPreferences { currentPreferences in
      currentPreferences = preferences
    }
    programInputDevices = definition.inputDevices.map { device in
      var runtimeDevice = device
      runtimeDevice.physicalDeviceID = preferences.physicalDeviceIDsByInputDeviceID[device.id]
      return runtimeDevice
    }
    workspaceAudioChannels = definition.audioChannels
    visions = definition.visions
    workspaceVideoComponents = definition.videoComponents
    if let selectedRecord = programLibrary.records.first(where: {
      $0.name == selectedProgramDefinitionName
    }) {
      compositeProgramDefinition = resolvedComposite(
        selectedRecord.composite,
        programName: selectedRecord.name
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

    do {
      let records = programLibrary.records.map { record in
        var updated = record
        updated.composite.steps.removeAll { $0.id == id }
        return updated
      }
      try programLibrary.replaceRecords(records, selectedName: selectedProgramDefinitionName)
    } catch {
      appendLog("Video Component could not be removed from Programs: \(error.localizedDescription)")
      return
    }

    compositeProgramDefinition = updatedComposite
    workspaceVideoComponents.removeAll { $0.id == id }
    var preferences = programPreferences
    preferences.removeVideoComponentReference(named: id)
    replaceProgramPreferences(with: preferences)
    selectedSidebarItem = .streamSettings
    syncWorkspaceFromCurrentProgramLibrary()
    updateWorkspaceWindowDirtyState()
  }

  private func updateProgramAudioGains(preferences: ProgramPreferences) {
    audioCoordinator.monitor.updateGains(
      audioChannels: effectiveWorkspaceAudioChannels,
      preferences: preferences
    )
  }

  @discardableResult
  private func restartAudioMonitor() -> Bool {
    shutdownCoordinator.requestStart { _ in
      await performRestartAudioMonitor().value
    }
  }

  private func performRestartAudioMonitor() -> Task<Void, Never> {
    let audioChannels = effectiveWorkspaceAudioChannels
    let inputAudioDeviceMappings = inputAudioDeviceMappings
    let workspaceInputDevices = programInputDevices
    let resolvedInputAudioDeviceMappings = mappedInputAudioDeviceIDs(
      composite: compositeProgramDefinition,
      audioChannels: audioChannels,
      workspaceInputDevices: workspaceInputDevices,
      inputAudioDeviceMappings: inputAudioDeviceMappings
    )
    let programPreferences = programPreferences
    let inputPassthroughChannelKeys = inputAudioPassthroughChannelKeys
    return audioCoordinator.restart(
      audioChannels: audioChannels,
      inputAudioDeviceMappings: resolvedInputAudioDeviceMappings,
      programPreferences: programPreferences,
      inputPassthroughChannelKeys: inputPassthroughChannelKeys,
      shouldRemainRunning: shutdownCoordinator.shouldAllowResourceStart,
      failureHandler: { failure in
        appendLog("Audio monitor interrupted: \(errorDescription(failure))")
      },
      errorHandler: { error in
        appendLog("Audio monitor failed: \(errorDescription(error))")
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
    guard workspaceFeatureAvailability.supportsVision, let sessionTaskQueue else { return }
    visionFeature.submit(
      vision,
      source: .normal,
      taskQueue: sessionTaskQueue,
      context: visionFeatureContext
    )
  }

  private func synchronizeVisionFeature() {
    guard workspaceFeatureAvailability.supportsVision, let sessionTaskQueue else {
      visionFeature.stop()
      return
    }
    visionFeature.synchronize(
      visions: visions,
      taskQueue: sessionTaskQueue,
      context: visionFeatureContext
    )
  }

  private var visionFeatureContext: WorkspaceVisionFeatureContext {
    WorkspaceVisionFeatureContext(
      visionNamed: { id in visions.first { $0.id == id } },
      imageForVision: imageForVision(_:),
      recordingPackageDirectory: { outputCoordinator.recordService?.packageDirectory },
      appendLog: appendLog(_:)
    )
  }

  private func imageForVision(_ vision: WorkspaceVisionDefinition) throws -> CIImage {
    let pixelBuffer: CVPixelBuffer?
    switch vision.source {
    case .currentProgramOutput:
      pixelBuffer = selectedProgramRuntime.latestFrame()?.pixelBuffer
    case .inputDevice(let id):
      guard let inputDevice = programInputDevices.first(where: { $0.id == id }) else {
        throw WorkspaceVisionFeatureError.referencedInputDeviceMissing
      }
      guard let physicalDeviceID = inputDevice.physicalDeviceID else {
        throw WorkspaceVisionFeatureError.inputDeviceHasNoPhysicalCamera
      }
      pixelBuffer = workspaceCaptureSessionCoordinator.latestPixelBuffer(
        forCameraID: physicalDeviceID)
    }
    guard let pixelBuffer else {
      throw WorkspaceVisionFeatureError.frameUnavailable
    }
    return CIImage(cvPixelBuffer: pixelBuffer)
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

  private func connectYouTubeBroadcast(
    _ broadcast: YouTubeLiveBroadcast,
    operationID: UUID,
    logger: EventTaskLogger
  ) async {
    guard let broadcastID = broadcast.id else {
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
    guard !effectiveWorkspaceAudioChannels.isEmpty else {
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
      selectedProgramRuntime.updateProgram(configuration)
      try await requestRequiredCaptureAccess(configuration: configuration)
      guard await synchronizeResourcesAfterRequiredCaptureAccess() else { return }
      let accessToken = try await authState.validAccessToken(
        configuration: oauthClientState.configuration
      )
      guard outputCoordinator.operationID == operationID,
        outputCoordinator.lifecycleState == .starting
      else {
        return
      }
      outputDestination.youtube.existingBroadcastID = broadcastID

      let result = try await youtubeClientService.createDASHStream(
        accessToken: accessToken,
        request: YouTubeClientService.DASHStreamRequest(
          title: outputDestination.youtube.streamTitle,
          description: outputDestination.youtube.streamDescription,
          resolution: derivedYouTubeStreamResolution,
          frameRate: derivedYouTubeStreamFrameRate,
          usesTemporaryStream: true,
          existingBroadcast: broadcast
        )
      )
      if authState.channelID == nil {
        authState.refreshChannelID(configuration: oauthClientState.configuration)
      }
      guard outputCoordinator.operationID == operationID,
        outputCoordinator.lifecycleState == .starting
      else {
        do {
          try await youtubeClientService.rollbackDASHStreamCreation(
            accessToken: accessToken,
            result: result
          )
        } catch {
          logError("Cancelled YouTube broadcast cleanup failed", error: error)
          appendLog("Cancelled YouTube broadcast cleanup failed: \(errorDescription(error))")
        }
        return
      }
      guard let dashEndpoint = result.dashEndpoint else {
        appendLog("YouTube LiveStream did not include a DASH endpoint.")
        markOutputSessionReadyToRestart(operationID: operationID)
        return
      }

      let youtubeOutputServiceProcess =
        outputCoordinator.youtubeOutputServiceProcess ?? YouTubeOutputServiceProcessClient()
      outputCoordinator.youtubeOutputServiceProcess = youtubeOutputServiceProcess
      let mediaHub = ProgramOutputMediaHub()
      let session = ActiveProgramOutputSession(
        currentProgramRuntime: selectedProgramRuntime,
        mediaHub: mediaHub,
        programRuntimeTransitionStateHandler: { [weak outputCoordinator] isTransitioning in
          outputCoordinator?.isProgramRuntimeTransitioning = isTransitioning
        }
      )
      outputCoordinator.currentMediaHub = mediaHub
      outputCoordinator.currentSession = session
      createSessionTaskQueue()
      synchronizeVisionFeature()
      if outputMode.recordsLocally {
        localOutputStore.beginAccess(to: outputBaseDirectory)
      }
      let audioDeviceIDsByInputKey = mappedInputAudioDeviceIDs(
        composite: configuration.composite,
        audioChannels: configuration.audioChannels,
        workspaceInputDevices: programInputDevices,
        inputAudioDeviceMappings: inputAudioDeviceMappings
      )
      let audioDeviceNamesByInputKey = mappedInputAudioDeviceNames(
        composite: configuration.composite,
        audioChannels: configuration.audioChannels,
        workspaceInputDevices: programInputDevices
      )
      let outputFailureHandler: @MainActor (Error) -> Void = { error in
        guard outputCoordinator.operationID == operationID else { return }
        reportOutputFailure(
          error,
          source: .outputSession,
          operationID: operationID,
          outputMode: outputMode
        )
      }
      let youtubeFailureHandler: @MainActor (Error) -> Void = { error in
        guard outputCoordinator.operationID == operationID else { return }
        reportOutputFailure(
          error,
          source: .youtube,
          operationID: operationID,
          outputMode: outputMode
        )
      }
      let recordFailureHandler: @MainActor (Error) -> Void = { error in
        guard outputCoordinator.operationID == operationID else { return }
        reportOutputFailure(
          error,
          source: .recording,
          operationID: operationID,
          outputMode: outputMode
        )
      }
      let youtubeService = YouTubeOutputWorkspaceService(
        endpoint: dashEndpoint,
        configuration: configuration,
        continuityStore: dashStreamContinuityStore,
        boundary: youtubeOutputServiceProcess,
        eventHandler: { appendLog($0) },
        failureHandler: youtubeFailureHandler,
        readyHandler: { [weak session] in session?.requestVideoKeyFrame() })
      outputCoordinator.installYouTubeService(youtubeService, on: mediaHub)
      try await startAndWait(youtubeService: youtubeService)
      if outputMode.recordsLocally {
        let recordService = try ProgramRecordService(
          baseDirectory: outputBaseDirectory,
          recordID: ProgramRecordService.makeRecordID(),
          writerConfiguration: ProgramOutputEncodingConfiguration.make(
            configuration: configuration),
          audioTracks: ProgramRecordAudioTrack.make(
            deviceIDsByInputKey: audioDeviceIDsByInputKey,
            deviceNamesByInputKey: audioDeviceNamesByInputKey),
          diagnosticsContext: applicationRouter.recordingDiagnosticsContextIfEnabled(),
          failureHandler: recordFailureHandler)
        outputCoordinator.installRecordService(recordService, on: mediaHub)
        try await startAndWait(recordService: recordService)
        appendLog("Recording package started: \(recordService.packageDirectory.path)")
      }
      try await startAndWait(
        session: session,
        programPreferences: programPreferences,
        audioDeviceIDsByInputKey: audioDeviceIDsByInputKey,
        eventHandler: { message in
          appendLog(message)
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
          logOutputServiceStopFailure(error, context: "cancelled startup cleanup")
        }
        return
      }
      outputCoordinator.lifecycleState = .running
      outputCoordinator.activeMode = outputMode
      outputCoordinator.recordService?.recordOutputStarted()
      await logger.append(.outputStarted)
      RecordingDockStatusController.shared.setStatus(
        outputMode.recordsLocally ? .recording : nil,
        for: recordingDockStatusID)
      appendLog(
        result.reusedBoundStream
          ? "Connected YouTube broadcast \(broadcastID) using existing bound DASH LiveStream \(result.stream.id ?? "(missing stream id)")."
          : "Connected YouTube broadcast \(broadcastID) to temporary DASH LiveStream \(result.stream.id ?? "(missing stream id)")."
      )
    } catch {
      guard outputCoordinator.operationID == operationID else { return }
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
    eventCoordinator.enqueue { logger in
      guard outputCoordinator.lifecycleState != .idle else { return }
      await logger.append(.outputStopRequested)
      outputDestination.youtube.existingBroadcastID = nil
      let operationID = outputCoordinator.invalidateOperations(for: .stopping)
      let session = outputCoordinator.currentSession
      let outputMode =
        outputCoordinator.activeMode ?? outputDestination.enabledCaptureOutputMode ?? .record
      session?.stop()
      if let session { await stopAndWait(for: session) }
      await finishSessionTasks()
      let serviceStopResult = await outputCoordinator.stopServices()
      await outputCoordinator.finishYouTubeOutputServiceProcess()
      guard outputCoordinator.operationID == operationID else { return }
      if outputMode.recordsLocally {
        localOutputStore.endAccess()
      }
      outputCoordinator.resetSession()
      if case .failure(let error) = serviceStopResult {
        presentOutputServiceStopFailure(error, context: "stopping output")
        await logger.append(.outputStopped)
        return
      }
      outputCoordinator.lifecycleState = .idle
      await logger.append(.outputStopped)
      RecordingDockStatusController.shared.setStatus(nil, for: recordingDockStatusID)
      appendLog("Output stopped.")
    }
  }

  @discardableResult
  private func startOutputSession() -> Bool {
    guard canStartOutputSession else { return false }
    guard saveWorkspaceForOutput() != nil else { return false }
    enterOutputMode()
    startLoadedOutputSession()
    return true
  }

  private func enterOutputMode() {
    buildOutputPipelines()
    selectedSidebarItem = .streamSettings
    windowMode = .output
  }

  private func buildOutputPipelines() {
    for record in programLibrary.records {
      let runtime = programRuntime(for: record)
      runtime.updateProgram(programConfiguration(for: record))
      runtime.updateProgramPreferences(programPreferences)
    }
  }

  /// Starts an Output Operation while the same Workspace Window owns both the
  /// persisted document lock and the live session.
  private func startLoadedOutputSession() {
    guard canStartOutputSession else { return }
    shutdownCoordinator.requestStart { _ in
      eventCoordinator.enqueue { logger in
        guard canBeginOutputSession else { return }
        await logger.append(.outputStartRequested)
        await beginOutputSession(logger: logger)
      }
    }
  }

  private func beginOutputSession(logger: EventTaskLogger) async {
    guard activeOutputProfile != nil else {
      appendLog("This Workspace uses a legacy output configuration. Select SDR 1080p60 before starting output.")
      outputCoordinator.lifecycleState = .readyToRestart
      return
    }
    if outputCoordinator.lifecycleState != .readyToRestart {
      dashStreamContinuityStore.beginNewOutputSession()
    }
    let operationID = outputCoordinator.beginStarting()
    if outputDestination.youtube.isEnabled {
      await startYouTubeOutput(operationID: operationID, logger: logger)
    } else if outputDestination.recording.isEnabled {
      await startRecording(operationID: operationID, logger: logger)
    } else {
      outputCoordinator.lifecycleState = .idle
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
      await handleOutputFailure(failure, logger: logger)
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

  private func stopAndWait(for session: ActiveProgramOutputSession) async {
    await withCheckedContinuation { continuation in
      session.stop { continuation.resume() }
    }
  }

  private func startAndWait(
    session: ActiveProgramOutputSession,
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

  private func startAndWait(recordService: ProgramRecordService) async throws {
    try await withCheckedThrowingContinuation { continuation in
      recordService.start { continuation.resume(with: $0) }
    }
  }

  private func startAndWait(youtubeService: YouTubeOutputWorkspaceService) async throws {
    try await withCheckedThrowingContinuation { continuation in
      youtubeService.start { continuation.resume(with: $0) }
    }
  }

  private func pauseOutputSession() {
    guard outputCoordinator.lifecycleState == .running,
      outputCoordinator.currentSession != nil
    else {
      return
    }

    eventCoordinator.enqueue { logger in
      guard outputCoordinator.lifecycleState == .running,
        let session = outputCoordinator.currentSession
      else { return }
      await logger.append(.outputStopRequested)
      let operationID = outputCoordinator.invalidateOperations(for: .pausing)
      let outputMode = outputCoordinator.activeMode
      session.stop()
      await stopAndWait(for: session)
      await finishSessionTasks()
      let serviceStopResult = await outputCoordinator.stopServices()
      await outputCoordinator.finishYouTubeOutputServiceProcess()
      guard outputCoordinator.operationID == operationID,
        outputCoordinator.lifecycleState == .pausing
      else {
        return
      }
      if outputMode?.recordsLocally == true {
        localOutputStore.endAccess()
      }
      outputCoordinator.resetSession()
      if case .failure(let error) = serviceStopResult {
        presentOutputServiceStopFailure(error, context: "pausing output")
        await logger.append(.outputStopped)
        return
      }
      outputCoordinator.lifecycleState = .readyToRestart
      await logger.append(.outputStopped)
      RecordingDockStatusController.shared.setStatus(
        outputMode?.recordsLocally == true ? .paused : nil,
        for: recordingDockStatusID)
      appendLog(
        "Output paused. Press Start to begin a new session with the current Output Settings.")
    }
  }

  private func resetSession() {
    guard
      outputCoordinator.lifecycleState != .starting,
      outputCoordinator.lifecycleState != .pausing,
      outputCoordinator.lifecycleState != .stopping
    else {
      return
    }

    if outputCoordinator.lifecycleState == .running {
      if restartActiveOutputSession(reason: .manualReset) {
        appendLog("Session reset requested complete output reconstruction.")
      }
      return
    }

    refreshCameras()
    _ = restartAudioMonitor()
    appendLog("Session reset requested device rediscovery and capture restart.")
  }

  @discardableResult
  private func restartActiveOutputSession(reason: ActiveOutputSessionRestartReason) -> Bool {
    guard outputCoordinator.lifecycleState == .running,
      outputCoordinator.currentSession != nil,
      let currentOutputMode = outputCoordinator.activeMode
    else {
      return false
    }
    if reason == .recordingSplit, !currentOutputMode.recordsLocally {
      return false
    }

    return eventCoordinator.enqueue { logger in
      guard outputCoordinator.lifecycleState == .running,
        let session = outputCoordinator.currentSession,
        let outputMode = outputCoordinator.activeMode
      else { return }
      if reason == .recordingSplit, !outputMode.recordsLocally { return }
      await logger.append(.outputReconstructionRequested)
      let operationID = outputCoordinator.invalidateOperations(for: .stopping)
      let selectedYouTubeBroadcastID = outputDestination.youtube.existingBroadcastID
      outputCoordinator.recordService?.recordOutputReconstructionRequested()
      session.stop()
      appendLog(reason.stoppingLogMessage)
      await stopAndWait(for: session)
      await finishSessionTasks()
      let serviceStopResult = await outputCoordinator.stopServices()
      guard outputCoordinator.operationID == operationID,
        outputCoordinator.lifecycleState == .stopping
      else {
        return
      }
      if outputMode.recordsLocally {
        localOutputStore.endAccess()
      }
      outputCoordinator.resetSession()
      if case .failure(let error) = serviceStopResult {
        presentOutputServiceStopFailure(error, context: reason.stoppingLogMessage)
        await logger.append(.outputStopped)
        return
      }
      outputDestination.youtube.existingBroadcastID = selectedYouTubeBroadcastID
      outputCoordinator.lifecycleState = .readyToRestart
      await logger.append(.outputStopped)

      if reason == .manualReset {
        refreshCameras()
        _ = restartAudioMonitor()
      }

      shutdownCoordinator.requestStart { _ in
        eventCoordinator.enqueue { restartLogger in
          guard outputCoordinator.operationID == operationID,
            outputCoordinator.lifecycleState == .readyToRestart
          else {
            return
          }
          await restartLogger.append(.outputRestartRequested)
          appendLog(reason.startingLogMessage)
          await beginOutputSession(logger: restartLogger)
        }
      }
    }
  }

  private func startYouTubeOutput(operationID: UUID, logger: EventTaskLogger) async {
    isLoadingBroadcasts = true
    defer { isLoadingBroadcasts = false }

    do {
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
      await connectYouTubeBroadcast(broadcast, operationID: operationID, logger: logger)
    } catch {
      if outputCoordinator.operationID == operationID {
        outputCoordinator.lifecycleState = .readyToRestart
      }
      appendLog("Broadcast list failed: \(errorDescription(error))")
      logError("Broadcast list failed", error: error)
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
        .first { $0.id == outputDestination.youtube.existingBroadcastID }?
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

  private func startRecording(operationID: UUID, logger: EventTaskLogger) async {
    guard outputDestination.recording.isEnabled, !outputDestination.youtube.isEnabled else {
      appendLog("Select Record before starting local recording.")
      markOutputSessionReadyToRestart(operationID: operationID)
      return
    }
    guard outputCoordinator.lifecycleState == .starting,
      outputCoordinator.operationID == operationID
    else {
      return
    }
    guard !effectiveWorkspaceAudioChannels.isEmpty else {
      appendLog("Configure a Workspace Audio Channel before starting output.")
      markOutputSessionReadyToRestart(operationID: operationID)
      return
    }

    do {
      let configuration = activeProgramConfiguration()
      selectedProgramRuntime.updateProgram(configuration)
      try await requestRequiredCaptureAccess(configuration: configuration)
      guard await synchronizeResourcesAfterRequiredCaptureAccess() else { return }
      guard outputCoordinator.operationID == operationID,
        outputCoordinator.lifecycleState == .starting
      else {
        return
      }
      let mediaHub = ProgramOutputMediaHub()
      let session = ActiveProgramOutputSession(
        currentProgramRuntime: selectedProgramRuntime,
        mediaHub: mediaHub,
        programRuntimeTransitionStateHandler: { [weak outputCoordinator] isTransitioning in
          outputCoordinator?.isProgramRuntimeTransitioning = isTransitioning
        }
      )
      outputCoordinator.currentMediaHub = mediaHub
      outputCoordinator.currentSession = session
      createSessionTaskQueue()
      synchronizeVisionFeature()
      localOutputStore.beginAccess(to: outputBaseDirectory)
      let audioDeviceIDsByInputKey = mappedInputAudioDeviceIDs(
        composite: configuration.composite,
        audioChannels: configuration.audioChannels,
        workspaceInputDevices: programInputDevices,
        inputAudioDeviceMappings: inputAudioDeviceMappings
      )
      let audioDeviceNamesByInputKey = mappedInputAudioDeviceNames(
        composite: configuration.composite,
        audioChannels: configuration.audioChannels,
        workspaceInputDevices: programInputDevices
      )
      let outputFailureHandler: @MainActor (Error) -> Void = { error in
        guard outputCoordinator.operationID == operationID else { return }
        reportOutputFailure(
          error,
          source: .outputSession,
          operationID: operationID,
          outputMode: .record
        )
      }
      let recordFailureHandler: @MainActor (Error) -> Void = { error in
        guard outputCoordinator.operationID == operationID else { return }
        reportOutputFailure(
          error,
          source: .recording,
          operationID: operationID,
          outputMode: .record
        )
      }
      let recordService = try ProgramRecordService(
        baseDirectory: outputBaseDirectory,
        recordID: ProgramRecordService.makeRecordID(),
        writerConfiguration: ProgramOutputEncodingConfiguration.make(configuration: configuration),
        audioTracks: ProgramRecordAudioTrack.make(
          deviceIDsByInputKey: audioDeviceIDsByInputKey,
          deviceNamesByInputKey: audioDeviceNamesByInputKey),
        diagnosticsContext: applicationRouter.recordingDiagnosticsContextIfEnabled(),
        failureHandler: recordFailureHandler)
      outputCoordinator.installRecordService(recordService, on: mediaHub)
      try await startAndWait(recordService: recordService)
      appendLog("Recording package started: \(recordService.packageDirectory.path)")
      try await startAndWait(
        session: session,
        programPreferences: programPreferences,
        audioDeviceIDsByInputKey: audioDeviceIDsByInputKey,
        eventHandler: { message in
          appendLog(message)
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
    guard let serviceError = error as? ProgramRecordServiceError,
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
    programConfiguration(composite: compositeProgramDefinition)
  }

  private func programConfiguration(for record: SavedProgramDefinitionRecord)
    -> ProgramRuntimeConfiguration
  {
    return programConfiguration(
      composite: resolvedComposite(record.composite, programName: record.name)
    )
  }

  private func programConfiguration(
    composite: CompositeProgramDefinition
  ) -> ProgramRuntimeConfiguration {
    let size = (width: outputCanvas.canvasSize.width, height: outputCanvas.canvasSize.height)
    let audioChannels = effectiveWorkspaceAudioChannels
    let cameraIDsByInputKey = mappedInputCameraDeviceIDs(
      composite: composite,
      workspaceInputDevices: programInputDevices,
      inputCameraDeviceMappings: inputCameraDeviceMappings
    )
    return ProgramRuntimeConfiguration(
      composite: composite,
      audioChannels: audioChannels,
      outputProfile: activeOutputProfile ?? .sdr1080p60,
      canvasWidth: outputCanvas.canvasSize.width,
      canvasHeight: outputCanvas.canvasSize.height,
      outputWidth: size.width,
      outputHeight: size.height,
      frameRate: max(outputCanvas.programDefinitionFrameRate, 1),
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
    )
  }

  /// Installs the latest protobuf-backed Program projection once for every
  /// Workspace edit. Preview and output only consume this shared state.
  private func updateSelectedProgramRuntime() {
    selectedProgramRuntime.updateProgram(activeProgramConfiguration())
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

  private func requestRequiredCaptureAccess(configuration: ProgramRuntimeConfiguration) async throws
  {
    if configuration.composite.steps.contains(where: {
      $0.component.definition.usesInputCameraDevice
    }),
      await requestCaptureAccess(for: .video) == false
    {
      ldtxAppLogger.error("Camera access preflight failed before starting output.")
      throw CameraCaptureServiceError.cameraAccessDenied
    }

    if configuration.audioChannels.contains(where: {
      $0.component.definition.usesInputAudioDevice
    }),
      await requestCaptureAccess(for: .audio) == false
    {
      ldtxAppLogger.error("Microphone access preflight failed before starting output.")
      throw CameraCaptureServiceError.microphoneAccessDenied
    }
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
        workspaceCaptureSessionCoordinator.restartAllCaptureSessions {
          continuation.resume(returning: $0)
        }
      }
      logWorkspaceCaptureSessionFailures(
        failedRestartCameraIDs,
        prefix: "Workspace capture session restart failed for camera(s)"
      )
      await synchronizeInputDeviceCapturesAsync()
    }
    if !didScheduleRestart {
      heldOutputSession?.endVideoFrameHold()
    }
  }

  private func synchronizeInputDeviceCaptures() {
    shutdownCoordinator.requestStart { _ in
      await synchronizeInputDeviceCapturesAsync()
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
      await synchronizeInputDeviceCapturesAsync()
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

  private func applyOutputSettings(
    from draft: AppOutputSettings
  ) {
    outputDestination = draft
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

struct WorkspaceEditorWindow: View {
  let request: WorkspaceEditorWindowRequest
  let applicationRouter: LDTXApplicationRouter
  @ObservedObject var oauthClientState: OAuthClientState
  @ObservedObject var authState: YouTubeAuthState
  let youtubeClientService: YouTubeClientService
  let lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry

  var body: some View {
    WorkspaceWindowRuntime(
      request: request,
      applicationRouter: applicationRouter,
      oauthClientState: oauthClientState,
      authState: authState,
      youtubeClientService: youtubeClientService,
      lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry
    )
  }
}

private struct OutputSessionFailureAlert<Content: View>: View {
  let content: Content
  @Binding var errorDescription: String?

  var body: some View {
    content
      .alert("Output Failed", isPresented: isPresented, presenting: errorDescription) { _ in
        Button("OK", role: .cancel) {}
      } message: { description in
        Text(description)
      }
  }

  private var isPresented: Binding<Bool> {
    Binding(
      get: { errorDescription != nil },
      set: { if !$0 { errorDescription = nil } }
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
    case .streamSettings: return nil
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
}

@MainActor
final class WorkspaceCommandCoordinator: ObservableObject {
  static let shared = WorkspaceCommandCoordinator()

  @Published private(set) var activeActions: WorkspaceActions?
  private var actionsByWorkspaceID: [Int: WorkspaceActions] = [:]
  private var activeWorkspaceID: Int?

  func register(workspaceID: Int, actions: WorkspaceActions) {
    actionsByWorkspaceID[workspaceID] = actions
    if activeWorkspaceID == nil {
      activate(workspaceID: workspaceID)
    } else if activeWorkspaceID == workspaceID {
      activeActions = actions
    }
  }

  func activate(workspaceID: Int) {
    guard let actions = actionsByWorkspaceID[workspaceID] else { return }
    activeWorkspaceID = workspaceID
    activeActions = actions
  }

  func unregister(workspaceID: Int) {
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

private final class WorkspaceWindowCloseCoordinator: NSObject, NSWindowDelegate {
  typealias CloseOperation = @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void
  typealias BecomeKeyOperation = @MainActor () -> Void

  private var onClose: CloseOperation?
  private var onBecomeKey: BecomeKeyOperation?
  private weak var observedWindow: NSWindow?
  private weak var previousDelegate: (any NSWindowDelegate)?
  private var closeIsAllowed = false
  private var closeIsPending = false
  private var installationTask: Task<Void, Never>?
  private weak var pendingWindow: NSWindow?

  @MainActor
  func beginInstalling(
    window: NSWindow?,
    onClose: @escaping CloseOperation,
    onBecomeKey: @escaping BecomeKeyOperation
  ) {
    self.onClose = onClose
    self.onBecomeKey = onBecomeKey
    guard let window else { return }
    if observedWindow === window, window.delegate === self { return }
    if pendingWindow === window, installationTask != nil { return }
    installationTask?.cancel()
    pendingWindow = window
    installationTask = Task { @MainActor in
      // SwiftUI assigns its own delegate while finishing WindowGroup
      // construction. Install after that assignment so this proxy remains
      // the final delegate and forwards the standard behavior.
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      self.install(window: window, onClose: onClose, onBecomeKey: onBecomeKey)
      self.pendingWindow = nil
      self.installationTask = nil
    }
  }

  @MainActor
  func install(
    window: NSWindow?,
    onClose: @escaping CloseOperation,
    onBecomeKey: @escaping BecomeKeyOperation
  ) {
    self.onClose = onClose
    self.onBecomeKey = onBecomeKey
    guard let window else {
      ldtxAppLogger.error("Could not install Workspace window close gate: no key window")
      return
    }
    if observedWindow === window, window.delegate === self { return }
    if let observedWindow, observedWindow.delegate === self {
      observedWindow.delegate = previousDelegate
    }
    observedWindow = window
    previousDelegate = window.delegate
    window.delegate = self
    if window.isKeyWindow { onBecomeKey() }
    ldtxAppLogger.notice("Installed Workspace window close gate")
  }

  @MainActor
  func windowDidBecomeKey(_ notification: Notification) {
    onBecomeKey?()
    previousDelegate?.windowDidBecomeKey?(notification)
  }

  @MainActor
  func updateDocumentEdited(_ isDocumentEdited: Bool) {
    (observedWindow ?? pendingWindow)?.isDocumentEdited = isDocumentEdited
  }

  @MainActor
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    ldtxAppLogger.notice("Workspace window close requested")
    guard !closeIsAllowed else { return true }
    guard !closeIsPending, let onClose else { return false }
    guard previousDelegate?.windowShouldClose?(sender) ?? true else { return false }
    closeIsPending = true
    sender.orderOut(nil)
    onClose { [weak self, weak sender] in
      guard let self, let sender else { return }
      self.closeIsAllowed = true
      sender.performClose(nil)
    }
    return false
  }

  override func responds(to selector: Selector!) -> Bool {
    super.responds(to: selector) || previousDelegate?.responds(to: selector) == true
  }

  override func forwardingTarget(for selector: Selector!) -> Any? {
    if previousDelegate?.responds(to: selector) == true {
      return previousDelegate
    }
    return super.forwardingTarget(for: selector)
  }
}

private struct WorkspaceDocumentLifecycle: ViewModifier {
  var selectedProgramName: String?
  var isWorkspaceDirty: Bool
  var performStartupTasks: () -> Void
  var updateWorkspaceWindowDirtyState: () -> Void

  func body(content: Content) -> some View {
    content
      .task {
        performStartupTasks()
      }
      .onChange(of: isWorkspaceDirty) { _, _ in
        updateWorkspaceWindowDirtyState()
      }
  }
}

private struct ProgramRuntimeObservation: ViewModifier {
  var programPreferencesRevision: UInt64
  var compositeProgramDefinition: CompositeProgramDefinition
  var workspaceAudioChannels: [ProgramAudioChannel]
  var outputCanvasState: OutputCanvasModel.State
  var inputAudioDeviceMappings: [String: String]
  var workspaceInputDevices: [WorkspaceInputDeviceRecord]
  var programPreferencesRevisionChanged: () -> Void
  var programDefinitionChanged: () -> Void
  var workspaceAudioChannelsChanged: () -> Void
  var outputCanvasChanged: () -> Void
  var audioDeviceMappingChanged: () -> Void
  var workspaceInputDevicesChanged: () -> Void

  func body(content: Content) -> some View {
    content
      .onChange(of: programPreferencesRevision) { _, _ in
        programPreferencesRevisionChanged()
      }
      .onChange(of: compositeProgramDefinition) { _, _ in
        programDefinitionChanged()
      }
      .onChange(of: workspaceAudioChannels) { _, _ in
        workspaceAudioChannelsChanged()
      }
      .onChange(of: outputCanvasState) { _, _ in
        outputCanvasChanged()
      }
      .onChange(of: inputAudioDeviceMappings) { _, _ in
        audioDeviceMappingChanged()
      }
      .onChange(of: workspaceInputDevices) { _, _ in
        workspaceInputDevicesChanged()
      }
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
