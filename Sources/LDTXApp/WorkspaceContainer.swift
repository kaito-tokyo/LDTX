// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AppKit
import CoreImage
import Foundation
import LDTXAppUI
import LDTXAutomation
import LDTXCapture
import LDTXDash
import LDTXProgram
import LDTXProgramRendering
import LDTXProgramRuntime
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
  let activeProgramRuntime: ActiveProgramRuntime

  init() {
    let captureSessionCoordinator = WorkspaceCaptureSessionCoordinator()
    self.captureSessionCoordinator = captureSessionCoordinator
    activeProgramRuntime = AppFeatureComposition.makeActiveProgramRuntime(
      captureSessionCoordinator: captureSessionCoordinator
    )
  }
}

struct WorkspaceContainer: View {
  @Environment(\.dismissWindow) private var dismissWindow
  private let request: WorkspaceSceneRequest
  private let applicationRouter: LDTXApplicationRouter
  @ObservedObject var oauthClientState: OAuthClientState
  @ObservedObject var authState: YouTubeAuthState
  private let youtubeClientService: YouTubeClientService
  @StateObject private var runtimeState: WorkspaceRuntimeState
  @State private var shutdownCoordinator = WorkspaceShutdownCoordinator()
  @State private var windowCloseCoordinator = WorkspaceWindowCloseCoordinator()
  @State private var audioCoordinator = WorkspaceAudioCoordinator()
  @State private var eventCoordinator = WorkspaceEventCoordinator()
  @State private var outputCoordinator = WorkspaceOutputCoordinator()
  @State private var streamStatus = "No broadcast"
  @State private var captureStatus = "Idle"
  @State private var outputCanvas = OutputCanvasModel()
  @State private var outputDestination = OutputDestinationModel()
  @State private var existingBroadcasts: [YouTubeLiveBroadcast] = []
  @State private var compositeProgramDefinition = CompositeProgramDefinition()
  @State private var programInputDevices: [WorkspaceInputDeviceRecord] = []
  @State private var workspaceAudioChannels: [ProgramAudioChannel] = []
  @State private var visions: [WorkspaceVisionDefinition] = []
  @State private var automations: [WorkspaceAutomationDefinition] = []
  @State private var automationTasks: [String: DispatchSourceTimer] = [:]
  @State private var sessionTaskQueue: SessionTaskQueue?
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
  @State private var isProgramDefinitionDirty = false
  @State private var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?
  @State private var programAddErrorMessage: String?
  @State private var presentedErrorDialog: ErrorDialogKind?
  @State private var isShowingProgramRenameDialog = false
  @State private var proposedProgramName = ""
  @State private var captureFrameFeedback: OutputFrameCaptureFeedback?
  @StateObject private var automationState = AppAutomationState()

  private var workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator {
    runtimeState.captureSessionCoordinator
  }

  private var activeProgramRuntime: ActiveProgramRuntime {
    runtimeState.activeProgramRuntime
  }

  init(
    request: WorkspaceSceneRequest,
    applicationRouter: LDTXApplicationRouter,
    oauthClientState: OAuthClientState,
    authState: YouTubeAuthState,
    youtubeClientService: YouTubeClientService
  ) {
    self.request = request
    self.applicationRouter = applicationRouter
    self.oauthClientState = oauthClientState
    self.authState = authState
    self.youtubeClientService = youtubeClientService
    WorkspaceSceneSequence.reserve(
      window: request.windowSequence,
      unsaved: request.unsavedSequence
    )
    _runtimeState = StateObject(wrappedValue: WorkspaceRuntimeState())
  }

  var body: some View {
    workspaceView
      .background(
        WorkspaceWindowReader { window in
          windowCloseCoordinator.beginInstalling(window: window, onClose: stopWorkspace)
          windowCloseCoordinator.updateDocumentEdited(hasUnsavedWorkspaceChanges)
        }
      )
      .modifier(workspaceDocumentLifecycle)
      .modifier(outputSettingsPersistence)
      .modifier(programRuntimeObservation)
      .onDisappear {
        stopWorkspace()
      }
      .onChange(of: visions) { _, _ in
        syncWorkspaceFromCurrentProgramLibrary()
        synchronizeVisionFeature()
        updateWorkspaceWindowDirtyState()
      }
      .onChange(of: automations) { _, _ in
        syncWorkspaceFromCurrentProgramLibrary()
        synchronizeWorkspaceAutomations()
        updateWorkspaceWindowDirtyState()
      }
      .focusedSceneValue(\.workspaceActions, workspaceActions)
  }

  private var workspaceView: some View {
    LDTXAppUI.WorkspaceView(
      selectedSidebarItem: $selectedSidebarItem,
      selectedProgramDefinitionName: $selectedProgramDefinitionName,
      workspaceInputDevices: programInputDevicesBinding,
      workspaceAudioChannels: $workspaceAudioChannels,
      visions: visionsBinding,
      automations: automationsBinding,
      compositeProgramDefinition: $compositeProgramDefinition,
      programPreferences: programPreferencesBinding,
      saveProgramDefinitionCommand: $saveProgramDefinitionCommand,
      programAddErrorMessage: $programAddErrorMessage,
      presentedErrorDialog: $presentedErrorDialog,
      isShowingProgramRenameDialog: $isShowingProgramRenameDialog,
      proposedProgramName: $proposedProgramName,
      captureFrameFeedback: $captureFrameFeedback,
      outputCanvas: outputCanvas,
      outputDestination: outputDestination,
      visionRuntimePresenter: visionFeature.presenter,
      backgroundRemovalPreprocessorFactory: AppFeatureComposition
        .backgroundRemovalPreprocessorFactory,
      workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
      activeProgramRuntime: activeProgramRuntime,
      activeProgramSnapshot: activeProgramSnapshot(),
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
      isConnectingBroadcast: isConnectingBroadcast,
      isStreamingToYouTube: isStreamingToYouTube,
      isRecording: isRecording,
      localOutputStatus: localOutputStore.status,
      canSelectYouTubeBroadcast: canCreateLiveStream,
      isOutputSessionRunning: isOutputSessionRunning,
      outputSessionControlState: outputSessionControlState,
      isOutputOperationLocked: eventCoordinator.isLocked,
      canEditInputDevices: canEditInputDevices,
      canEditOutputSettings: canEditOutputSettings,
      isGlobalOutputSessionStartEnabled: isGlobalOutputSessionStartEnabled,
      globalOutputSessionStartAccessibilityLabel: globalOutputSessionStartAccessibilityLabel,
      globalOutputSessionStartHelp: globalOutputSessionStartHelp,
      globalOutputSessionStopHelp: globalOutputSessionStopHelp,
      isWorkspaceSaveToolbarEnabled: isWorkspaceSaveToolbarEnabled,
      updateProgramAudioGains: updateProgramAudioGains(preferences:),
      reloadSavedProgramDefinitions: reloadSavedProgramDefinitions,
      refreshCameras: refreshCameras,
      deleteWorkspaceInputDevice: deleteWorkspaceInputDevice(id:),
      saveProgramDefinitionRecord: saveProgramDefinitionRecord(_:),
      programDefinitionDirtyChanged: { isDirty in
        isProgramDefinitionDirty = isDirty
        updateWorkspaceWindowDirtyState()
      },
      stopOutputSession: stopOutputSession,
      startOutputSession: startOutputSession,
      pauseOutputSession: pauseOutputSession,
      resetSession: resetSession,
      addProgramDefinition: addProgramDefinition(named:),
      showProgramRenameDialog: showProgramRenameDialog,
      renameSelectedProgramDefinitionFromDialog: renameSelectedProgramDefinitionFromDialog,
      deleteSelectedProgramDefinition: deleteSelectedProgramDefinition,
      saveWorkspace: saveWorkspace,
      refreshExistingBroadcasts: refreshExistingBroadcasts,
      manageYouTubeBroadcasts: manageYouTubeBroadcasts,
      chooseLocalOutputDirectory: chooseLocalOutputDirectory,
      analyzeVision: analyzeVision,
      runAutomation: runAutomation,
      captureFrame: captureOutputFrame,
      openScreenshotsDirectory: openScreenshotsDirectory,
      featureAvailability: workspaceFeatureAvailability
    )
  }

  private var workspaceFeatureAvailability: WorkspaceFeatureAvailability {
    AppFeatureComposition.workspaceFeatureAvailability
  }

  private func captureOutputFrame() {
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
      if let pixelBuffer = activeProgramRuntime.latestFrame()?.pixelBuffer {
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
    let securityScopedDirectory = localOutputStore.selectedBaseDirectory
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
      { stopToken in
        defer { finish() }
        guard !stopToken.isStopRequested else { return }

        let didBeginAccess =
          securityScopedDirectory?.startAccessingSecurityScopedResource() == true
        defer {
          if didBeginAccess {
            securityScopedDirectory?.stopAccessingSecurityScopedResource()
          }
        }

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

  private var activeRecordingPackageDirectory: URL? {
    guard isRecording else { return nil }
    return outputCoordinator.recordService?.packageDirectory
  }

  private func performStartupTasks() {
    guard !didInitializeWorkspace else { return }
    didInitializeWorkspace = true
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
          dismissWindow(id: "workspace", value: request)
          return
        }
      }
    }
    updateWorkspaceWindowDirtyState()
    configureAutomationHandlers()
    registerAutomationWorkspace()
    refreshSavedProgramDefinitions()
    refreshAutomationSelectedProgram()
    refreshCameras()
    restartAudioMonitor()
  }

  private var workspaceDocumentLifecycle: WorkspaceDocumentLifecycle {
    WorkspaceDocumentLifecycle(
      selectedProgramName: selectedProgramDefinitionRecord?.name,
      isWorkspaceDirty: persistenceCoordinator.store.isDirty,
      performStartupTasks: performStartupTasks,
      refreshAutomationSelectedProgram: refreshAutomationSelectedProgram,
      updateWorkspaceWindowDirtyState: updateWorkspaceWindowDirtyState
    )
  }

  private var outputSettingsPersistence: OutputSettingsPersistence {
    OutputSettingsPersistence(
      outputDestination: outputDestination,
      persistOutputSettings: persistOutputSettings
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
      outputCanvasChanged: outputCanvasChanged,
      audioDeviceMappingChanged: { _ = restartAudioMonitor() },
      workspaceInputDevicesChanged: workspaceInputDevicesChanged
    )
  }

  private func stopWorkspace(completion: @escaping @MainActor @Sendable () -> Void = {}) {
    automationTasks.values.forEach { $0.cancel() }
    automationTasks.removeAll()
    visionFeature.stop()
    stopWorkspaceResources(completion: completion)
  }

  private func createSessionTaskQueue() {
    let outputCoordinator = outputCoordinator
    sessionTaskQueue = SessionTaskQueue(
      label: "tokyo.kaito.ldtx.workspace.session-data",
      finalizer: { completion in
        { _ in
          Task { @MainActor in
            await outputCoordinator.stopRecordService()
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
            outputCoordinator.activeMode ?? outputDestination.selectedCaptureOutputMode
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
          streamStatus = "Stopped"
          captureStatus = "Idle"
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
        applicationRouter.automationRouter.unregisterWorkspace(token: request.windowSequence)
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
    activeProgramRuntime.updateProgramPreferences(current)
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
    restartAudioMonitor()
  }

  private func outputCanvasChanged() {
    programDefinitionChanged()
    synchronizeInputDeviceCaptures()
  }

  private func markProgramDefinitionDirty() {
    isProgramDefinitionDirty = true
    updateWorkspaceWindowDirtyState()
  }

  private var workspaceActions: WorkspaceActions {
    WorkspaceActions(
      saveWorkspace: saveWorkspace,
      saveWorkspaceAs: saveWorkspaceAs
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

  private var hasUnsavedWorkspaceChanges: Bool {
    persistenceCoordinator.store.isDirty || isProgramDefinitionDirty
  }

  private var programInputDevicesBinding: Binding<[WorkspaceInputDeviceRecord]> {
    Binding(
      get: { programInputDevices },
      set: { newValue in
        if let (oldName, newName) = inputDeviceRename(from: programInputDevices, to: newValue) {
          performInputDeviceRename(from: oldName, to: newName, updatedDevices: newValue)
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

  private var automationsBinding: Binding<[WorkspaceAutomationDefinition]> {
    Binding(
      get: { automations },
      set: { newValue in
        if let (oldName, newName) = automationRename(from: automations, to: newValue) {
          performAutomationRename(from: oldName, to: newName)
        } else {
          automations = newValue
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

  private func automationRename(
    from oldValues: [WorkspaceAutomationDefinition],
    to newValues: [WorkspaceAutomationDefinition]
  ) -> (String, String)? {
    guard oldValues.count == newValues.count else { return nil }
    let changed = oldValues.indices.filter { oldValues[$0].name != newValues[$0].name }
    guard changed.count == 1, let index = changed.first else { return nil }
    var normalized = newValues[index]
    normalized.name = oldValues[index].name
    guard normalized == oldValues[index] else { return nil }
    return (oldValues[index].name, newValues[index].name)
  }

  private func currentWorkspaceDefinitionForRename() -> WorkspaceDefinition {
    WorkspaceDefinition(
      name: persistenceCoordinator.store.definition.name,
      programs: programLibrary.records,
      inputDevices: programInputDevices,
      audioChannels: workspaceAudioChannels,
      visions: visions,
      automations: automations
    )
  }

  private func currentWorkspacePreferencesForRename() -> WorkspacePreferences {
    var preferences = persistenceCoordinator.store.preferences
    preferences.programPreferences = programPreferencesStore.value
    preferences.physicalDeviceIDsByInputDeviceID = Dictionary(
      uniqueKeysWithValues: programInputDevices.compactMap { device in
        device.physicalDeviceID.map { (device.name, $0) }
      }
    )
    return preferences
  }

  private func performInputDeviceRename(
    from oldName: String,
    to newName: String,
    updatedDevices: [WorkspaceInputDeviceRecord]
  ) {
    do {
      var definition = currentWorkspaceDefinitionForRename()
      var preferences = currentWorkspacePreferencesForRename()
      try definition.renameInputDevice(from: oldName, to: newName, preferences: &preferences)
      try programLibrary.replaceRecords(definition.programs, selectedName: selectedProgramDefinitionName)
      programInputDevices = updatedDevices
      workspaceAudioChannels = definition.audioChannels
      visions = definition.visions
      automations = definition.automations
      compositeProgramDefinition.renameInputDevice(from: oldName, to: newName)
      programPreferencesStore.replace(with: preferences.programPreferences)
      if selectedSidebarItem == .inputDevice(oldName) {
        selectedSidebarItem = .inputDevice(newName)
      }
      syncWorkspaceFromCurrentProgramLibrary()
      persistWorkspacePreferences()
      synchronizeInputDeviceCaptures()
      restartAudioMonitor()
    } catch {
      appendLog("Input Device could not be renamed: \(error.localizedDescription)")
    }
  }

  private func performVisionRename(from oldName: String, to newName: String) {
    do {
      var definition = currentWorkspaceDefinitionForRename()
      try definition.renameVision(from: oldName, to: newName)
      visions = definition.visions
      automations = definition.automations
      if selectedSidebarItem == .vision(oldName) {
        selectedSidebarItem = .vision(newName)
      }
    } catch {
      appendLog("Vision could not be renamed: \(error.localizedDescription)")
    }
  }

  private func performAutomationRename(from oldName: String, to newName: String) {
    do {
      var definition = currentWorkspaceDefinitionForRename()
      try definition.renameAutomation(from: oldName, to: newName)
      visions = definition.visions
      automations = definition.automations
      if selectedSidebarItem == .automation(oldName) {
        selectedSidebarItem = .automation(newName)
      }
    } catch {
      appendLog("Automation could not be renamed: \(error.localizedDescription)")
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

  private func saveWorkspaceAs() {
    let panel = workspaceSavePanel(
      fileName: suggestedWorkspaceFileName,
      directoryURL: persistenceCoordinator.url?.deletingLastPathComponent()
        ?? iCloudDocumentsDirectory(),
      message: "Save the current LDTX Workspace.",
      prompt: "Save"
    )
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let packageURL = persistenceCoordinator.packageURL(for: url)
    guard packageURL.standardizedFileURL != persistenceCoordinator.url?.standardizedFileURL else {
      saveWorkspace(to: packageURL)
      return
    }
    do {
      let lock = try acquireWorkspaceLock(at: packageURL, createsPackageDirectory: true)
      var didActivateLock = false
      defer {
        if !didActivateLock { persistenceCoordinator.releaseLock(lock) }
      }
      guard saveWorkspace(to: packageURL) else { return }
      persistenceCoordinator.activateLock(lock)
      didActivateLock = true
    } catch {
      appendLog("Workspace could not be saved: \(error.localizedDescription)")
    }
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
      registerAutomationWorkspace()
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
      definition.automations = automations
    }
  }

  private func replaceWorkspaceStore(
    _ store: WorkspaceStore,
    url: URL?,
    clearsDetailSelection: Bool = true
  ) throws {
    persistenceCoordinator.replace(store: store, url: url)
    workspaceAudioChannels =
      store.definition.audioChannels.isEmpty
      ? store.definition.programs.first(where: { !$0.composite.audioChannels.isEmpty })?.composite
        .audioChannels ?? []
      : store.definition.audioChannels
    programInputDevices = store.definition.inputDevices.map { device in
      var runtimeDevice = device
      runtimeDevice.physicalDeviceID = store.preferences.physicalDeviceIDsByInputDeviceID[device.id]
      return runtimeDevice
    }
    inputCameraDeviceMappings = store.preferences.inputCameraDeviceMappings
    inputAudioDeviceMappings = store.preferences.inputAudioDeviceMappings
    inputAudioPassthroughChannelKeys = store.preferences.inputAudioMonitorChannelKeys
    visions = store.definition.visions
    automations = store.definition.automations
    synchronizeVisionFeature()
    synchronizeWorkspaceAutomations()
    isProgramDefinitionDirty = false
    updateWorkspaceWindowDirtyState()
    let selectedName =
      store.preferences.selectedProgramName ?? store.definition.programs.first?.name
    try programLibrary.replaceRecords(store.definition.programs, selectedName: selectedName)
    programPreferencesStore.replace(with: store.preferences.programPreferences)
    restoreOutputSettings()
    let selectedRecord = try programLibrary.ensureDefaultProgram()
    syncWorkspaceFromCurrentProgramLibrary()
    selectProgramDefinition(
      named: selectedRecord.name, clearsDetailSelection: clearsDetailSelection)
    synchronizeInputDeviceCaptures()
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

  private var isOutputSessionRunning: Bool {
    outputCoordinator.lifecycleState == .running
  }

  private var outputSessionControlState: OutputSessionControlState {
    switch outputCoordinator.lifecycleState {
    case .idle:
      .idle
    case .starting:
      .starting
    case .running:
      .running
    case .pausing:
      .pausing
    case .readyToRestart:
      .readyToRestart
    case .stopping:
      .stopping
    }
  }

  private var canEditInputDevices: Bool {
    !eventCoordinator.isLocked
      && (outputCoordinator.lifecycleState == .idle
        || outputCoordinator.lifecycleState == .readyToRestart)
  }

  private var canEditOutputSettings: Bool {
    !eventCoordinator.isLocked && outputCoordinator.lifecycleState == .idle
  }

  private var canStartOutputSession: Bool {
    !eventCoordinator.isLocked
      && shutdownCoordinator.shouldAllowResourceStart()
      && canBeginOutputSession
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
    guard let selectedExistingBroadcastID = outputDestination.selectedExistingBroadcastID else {
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

    return outputDestination.isRecordingEnabled || outputDestination.isYouTubeEnabled
  }

  private var canCreateLiveStream: Bool {
    if isLoadingBroadcasts || isConnectingBroadcast {
      return false
    }
    if isOutputSessionRunning {
      return false
    }
    return outputDestination.isYouTubeEnabled
  }

  private var globalOutputSessionStartAccessibilityLabel: String {
    switch outputDestination.selectedCaptureOutputMode {
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
    if outputDestination.isYouTubeEnabled,
      preferredExistingBroadcast == nil
    {
      return "Create or schedule a YouTube broadcast in Manage before connecting."
    }

    switch outputDestination.selectedCaptureOutputMode {
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
    programPreferencesStore.replace(with: persistenceCoordinator.store.preferences.programPreferences)
  }

  private func selectProgramDefinition(named name: String?, clearsDetailSelection: Bool = true) {
    if clearsDetailSelection {
      clearDetailSelection()
    }
    let selectedName = name ?? programLibrary.records.first?.name
    selectedProgramDefinitionName = selectedName
    persistenceCoordinator.store.editPreferences { $0.selectedProgramName = selectedName }
    persistWorkspacePreferences()
    if let record = savedProgramDefinition(named: selectedName) {
      compositeProgramDefinition = record.composite
      synchronizeWorkspaceAudioChannelsWithInputDevices()
      outputCanvas.sync(from: record)
      isProgramDefinitionDirty = false
      updateWorkspaceWindowDirtyState()
    } else {
      synchronizeWorkspaceAudioChannelsWithInputDevices()
    }
    restartAudioMonitor()
    synchronizeInputDeviceCaptures()
    refreshAutomationSelectedProgram()
  }

  private func clearDetailSelection() {
    selectedSidebarItem = .streamSettings
  }

  private func refreshAutomationSelectedProgram() {
    automationState.updateSelectedProgram(
      name: selectedProgramDefinitionRecord?.name ?? "",
      isScratchPad: false
    )
  }

  private func activeProgramDefinitionRecord() -> SavedProgramDefinitionRecord? {
    let name =
      selectedProgramDefinitionRecord?.name
      ?? selectedProgramDefinitionName
      ?? programLibrary.records.first?.name
    guard let name else {
      return nil
    }
    return SavedProgramDefinitionRecord(
      name: name,
      canvasWidth: outputCanvas.canvasSize.width,
      canvasHeight: outputCanvas.canvasSize.height,
      frameRateNumerator: max(outputCanvas.programDefinitionFrameRate, 1),
      frameRateDenominator: 1,
      composite: outputCanvas.applying(to: compositeProgramDefinition),
      inputDevices: []
    )
  }

  private func configureAutomationHandlers() {
    automationState.updateHandlers(
      AppAutomationHandlers(
        terminate: {
          appendLog("Automation requested app termination.")
          DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
          }
          return AppAutomationCommandResult(ok: true, message: "Termination requested.")
        },
        activeProgramDefinition: {
          activeProgramDefinitionRecord()
        },
        selectProgram: { name, isScratchPad in
          if isScratchPad {
            return AppAutomationCommandResult(
              ok: false, message: "Only saved Programs can be selected.")
          }

          guard savedProgramDefinition(named: name) != nil else {
            return AppAutomationCommandResult(ok: false, message: "Program not found: \(name)")
          }
          selectProgramDefinition(named: name)
          return AppAutomationCommandResult(ok: true, message: "Selected Program: \(name)")
        },
        selectInputDevice: { workspaceInputDeviceID, physicalDeviceID in
          guard canEditInputDevices else {
            return AppAutomationCommandResult(
              ok: false, message: "Pause output before changing Input Devices.")
          }
          return selectInputDevice(
            workspaceInputDeviceID: workspaceInputDeviceID,
            physicalDeviceID: physicalDeviceID
          )
        },
        startOutput: {
          guard canStartOutputSession else {
            return AppAutomationCommandResult(ok: true, message: "Output is already running.")
          }
          guard canStartProgramAudioMix else {
            return AppAutomationCommandResult(
              ok: false,
              message: "Configure a Workspace Audio Channel before starting output."
            )
          }

          startOutputSession()
          return AppAutomationCommandResult(ok: true, message: "Output start requested.")
        },
        stopOutput: {
          guard outputCoordinator.lifecycleState != .idle else {
            return AppAutomationCommandResult(ok: true, message: "Output is not running.")
          }

          stopOutputSession()
          return AppAutomationCommandResult(ok: true, message: "Output stop requested.")
        },
        startRecording: {
          guard canStartOutputSession else {
            if isRecording {
              return AppAutomationCommandResult(ok: true, message: "Recording is already running.")
            }
            return AppAutomationCommandResult(
              ok: false, message: "Another output session is already running.")
          }

          if outputCoordinator.lifecycleState == .idle {
            outputDestination.selectedCaptureOutputMode = .record
          } else if outputDestination.selectedCaptureOutputMode != .record {
            return AppAutomationCommandResult(
              ok: false, message: "Stop output before changing Output Settings.")
          }
          startOutputSession()
          return AppAutomationCommandResult(ok: true, message: "Recording start requested.")
        },
        stopRecording: {
          guard outputCoordinator.lifecycleState != .idle,
            outputDestination.selectedCaptureOutputMode.recordsLocally
          else {
            return AppAutomationCommandResult(ok: true, message: "Recording is not running.")
          }

          stopOutputSession()
          return AppAutomationCommandResult(ok: true, message: "Recording stop requested.")
        },
        splitRecording: {
          if let failure = RecordingSplitAutomationSupport.validationFailure(
            isOutputSessionRunning: isOutputSessionRunning,
            activeCaptureOutputMode: outputCoordinator.activeMode
          ) {
            return failure
          }
          guard restartActiveOutputSession(reason: .recordingSplit) else {
            return AppAutomationCommandResult(
              ok: false, message: "Recording split could not be started.")
          }
          appendLog("Recording split requested.")
          return AppAutomationCommandResult(ok: true, message: "Recording split requested.")
        },
        inputDevices: {
          programInputDevices
        },
        outputSettings: {
          outputSettingsProto()
        },
        setOutputSettings: { settings in
          applyOutputSettings(settings)
        }
      ))
  }

  private func registerAutomationWorkspace() {
    let documentURL = persistenceCoordinator.url?.standardizedFileURL
    let unsavedSequence = request.unsavedSequence ?? request.windowSequence
    let routingURL = documentURL ?? LDTXResourceURL.unsavedWorkspace(sequence: unsavedSequence)
    let title =
      documentURL?.deletingPathExtension().lastPathComponent
      ?? "New Workspace \(unsavedSequence)"
    do {
      try applicationRouter.automationRouter.registerWorkspace(
        token: request.windowSequence,
        url: routingURL,
        title: title,
        documentURL: documentURL,
        state: automationState
      )
    } catch {
      appendLog(
        "Workspace Automation routing could not be registered: \(error.localizedDescription)")
    }
  }

  private func outputSettingsProto() -> Ldtx_Automation_V1_OutputSettings {
    var settings = Ldtx_Automation_V1_OutputSettings()
    settings.captureOutputMode = outputDestination.selectedCaptureOutputMode.protoValue
    settings.recordingEnabled = outputDestination.isRecordingEnabled
    settings.youtubeEnabled = outputDestination.isYouTubeEnabled

    var youtube = Ldtx_Automation_V1_YouTubeOutputSettings()
    youtube.title = outputDestination.streamTitle
    youtube.description_p = outputDestination.streamDescription
    youtube.resolution = derivedYouTubeStreamResolution.protoValue
    youtube.frameRate = derivedYouTubeStreamFrameRate.protoValue
    youtube.usesTemporaryStream = true
    youtube.existingBroadcastID = outputDestination.selectedExistingBroadcastID ?? ""
    settings.youtube = youtube

    var recording = Ldtx_Automation_V1_RecordingOutputSettings()
    recording.baseDirectoryPath = localOutputStore.baseDirectory.path
    settings.recording = recording

    return settings
  }

  private func applyOutputSettings(
    _ settings: Ldtx_Automation_V1_OutputSettings
  ) -> AppAutomationCommandResult {
    guard canEditOutputSettings else {
      return AppAutomationCommandResult(
        ok: false,
        message: "Output settings cannot be changed while output is running."
      )
    }

    do {
      let toggles = try OutputToggleSelection.resolve(
        settings,
        current: OutputToggleSelection(
          recordingEnabled: outputDestination.isRecordingEnabled,
          youtubeEnabled: outputDestination.isYouTubeEnabled))
      outputDestination.isRecordingEnabled = toggles.recordingEnabled
      outputDestination.isYouTubeEnabled = toggles.youtubeEnabled

      if settings.hasYoutube {
        try applyYouTubeOutputSettings(settings.youtube)
      }

      if settings.hasRecording {
        try applyRecordingOutputSettings(settings.recording)
      }

      persistOutputSettings()
      appendLog("Automation updated Output Settings.")
      return AppAutomationCommandResult(ok: true, message: "Output Settings updated.")
    } catch let error as OutputSettingsAutomationError {
      return AppAutomationCommandResult(ok: false, message: error.message)
    } catch {
      return AppAutomationCommandResult(ok: false, message: error.localizedDescription)
    }
  }

  private func applyYouTubeOutputSettings(
    _ settings: Ldtx_Automation_V1_YouTubeOutputSettings
  ) throws {
    if settings.hasTitle {
      outputDestination.streamTitle = settings.title
    }
    if settings.hasDescription_p {
      outputDestination.streamDescription = settings.description_p
    }
    outputDestination.usesTemporaryStream = true
    if settings.hasExistingBroadcastID {
      let trimmed = settings.existingBroadcastID.trimmingCharacters(in: .whitespacesAndNewlines)
      outputDestination.selectedExistingBroadcastID = trimmed.isEmpty ? nil : trimmed
    }
  }

  private func applyRecordingOutputSettings(
    _ settings: Ldtx_Automation_V1_RecordingOutputSettings
  ) throws {
    guard settings.hasBaseDirectoryPath else { return }
    let trimmed = settings.baseDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw OutputSettingsAutomationError("Recording baseDirectoryPath must not be empty.")
    }

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw OutputSettingsAutomationError(
        "Recording baseDirectoryPath is not a directory: \(trimmed)")
    }
    localOutputStore.selectBaseDirectory(URL(fileURLWithPath: trimmed, isDirectory: true))
  }

  private func restoreOutputSettings() {
    let output = persistenceCoordinator.store.preferences.output
    if output.recordingEnabled != nil || output.youtubeEnabled != nil {
      if let recordingEnabled = output.recordingEnabled {
        outputDestination.isRecordingEnabled = recordingEnabled
      }
      if let youtubeEnabled = output.youtubeEnabled {
        outputDestination.isYouTubeEnabled = youtubeEnabled
      }
    } else if let mode = CaptureOutputMode(rawValue: output.captureOutputMode) {
      outputDestination.selectedCaptureOutputMode = mode
    }
    outputDestination.streamTitle = output.streamTitle
    outputDestination.streamDescription = output.streamDescription
    outputDestination.usesTemporaryStream = true
    outputDestination.selectedExistingBroadcastID = output.existingBroadcastID
    outputDestination.prefersColorPreview = output.prefersColorPreview

    if let baseDirectoryPath = output.localOutputBaseDirectoryPath, !baseDirectoryPath.isEmpty {
      localOutputStore.selectBaseDirectory(
        URL(fileURLWithPath: baseDirectoryPath, isDirectory: true))
    } else {
      localOutputStore.resetBaseDirectory()
    }
  }

  private func persistOutputSettings() {
    outputDestination.usesTemporaryStream = true
    persistenceCoordinator.store.editPreferences { preferences in
      preferences.output = WorkspaceOutputPreferences(
        captureOutputMode: outputDestination.selectedCaptureOutputMode.rawValue,
        existingBroadcastID: outputDestination.selectedExistingBroadcastID,
        streamTitle: outputDestination.streamTitle,
        streamDescription: outputDestination.streamDescription,
        prefersColorPreview: outputDestination.prefersColorPreview,
        localOutputBaseDirectoryPath: localOutputStore.baseDirectory.path,
        recordingEnabled: outputDestination.isRecordingEnabled,
        youtubeEnabled: outputDestination.isYouTubeEnabled
      )
    }
    persistWorkspacePreferences()
  }

  private func persistWorkspacePreferences() {
    persistenceCoordinator.store.editPreferences { preferences in
      preferences.programPreferences = programPreferencesStore.value
      preferences.physicalDeviceIDsByInputDeviceID = Dictionary(
        uniqueKeysWithValues: programInputDevices.compactMap { device in
          guard let physicalDeviceID = device.physicalDeviceID, !physicalDeviceID.isEmpty else {
            return nil
          }
          return (device.id, physicalDeviceID)
        }
      )
      preferences.inputCameraDeviceMappings = inputCameraDeviceMappings
      preferences.inputAudioDeviceMappings = inputAudioDeviceMappings
      preferences.inputAudioMonitorChannelKeys = inputAudioPassthroughChannelKeys
      preferences.selectedProgramName = selectedProgramDefinitionName
    }
    do {
      try persistenceCoordinator.savePreferences()
    } catch {
      appendLog("Workspace preferences could not be saved: \(error.localizedDescription)")
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

  private func showProgramRenameDialog() {
    guard let selectedName = selectedProgramDefinitionName else {
      return
    }
    proposedProgramName = selectedName
    isShowingProgramRenameDialog = true
  }

  private func renameSelectedProgramDefinitionFromDialog() {
    guard let selectedName = selectedProgramDefinitionName else {
      return
    }
    guard renameProgramDefinition(oldName: selectedName, to: proposedProgramName) != nil else {
      return
    }
    isShowingProgramRenameDialog = false
  }

  private func renameProgramDefinition(oldName: String, to proposedName: String) -> String? {
    do {
      guard let renamed = try programLibrary.rename(oldName: oldName, to: proposedName) else {
        return nil
      }
      if selectedProgramDefinitionName == oldName {
        selectedProgramDefinitionName = renamed.name
      }
      syncWorkspaceFromCurrentProgramLibrary()
      persistWorkspacePreferences()
      refreshAutomationSelectedProgram()
      return renamed.name
    } catch {
      appendLog("Program definitions could not be saved: \(error.localizedDescription)")
      return nil
    }
  }

  private func deleteProgramDefinition(named name: String) {
    let deletedSelectedProgram = selectedProgramDefinitionName == name
    do {
      try programLibrary.delete(named: name)
      syncWorkspaceFromCurrentProgramLibrary()
      persistWorkspacePreferences()
      guard deletedSelectedProgram else {
        return
      }
      if let replacement = programLibrary.records.first {
        selectProgramDefinition(named: replacement.name)
      } else {
        let replacement = try programLibrary.ensureDefaultProgram()
        syncWorkspaceFromCurrentProgramLibrary()
        selectProgramDefinition(named: replacement.name)
      }
    } catch {
      appendLog("Program definitions could not be saved: \(error.localizedDescription)")
    }
  }

  private func deleteSelectedProgramDefinition() {
    guard let selectedProgramDefinitionName else { return }
    deleteProgramDefinition(named: selectedProgramDefinitionName)
  }

  private func deleteWorkspaceInputDevice(id: String) {
    guard canEditInputDevices else { return }
    if let removedInputDevice = programInputDevices.first(where: { $0.id == id }) {
      var nextPreferences = programPreferencesStore.value
      nextPreferences.removeInputDevice(named: removedInputDevice.name)
      replaceProgramPreferences(with: nextPreferences)
    }
    programInputDevices.removeAll { $0.id == id }
    syncWorkspaceFromCurrentProgramLibrary()
    persistWorkspacePreferences()
    synchronizeInputDeviceCaptures()
    if selectedSidebarItem == .inputDevice(id) {
      if let replacementID = programInputDevices.first?.id {
        selectedSidebarItem = .inputDevice(replacementID)
      } else {
        clearDetailSelection()
      }
    }

    compositeProgramDefinition = compositeClearingInputDeviceReference(
      id, in: compositeProgramDefinition)
    workspaceAudioChannels = workspaceAudioChannels.map { channel in
      guard case .inputAudioDevice(var payload) = channel.component,
        payload.inputDeviceID == id
      else {
        return channel
      }
      payload.inputDeviceID = nil
      return ProgramAudioChannel(id: channel.id, component: .inputAudioDevice(payload))
    }
    restartAudioMonitor()
  }

  private func compositeClearingInputDeviceReference(
    _ inputDeviceID: String,
    in composite: CompositeProgramDefinition
  ) -> CompositeProgramDefinition {
    var updated = composite
    for stepIndex in updated.steps.indices {
      guard case .inputCameraDevice(var payload) = updated.steps[stepIndex].component,
        payload.inputDeviceID == inputDeviceID
      else {
        continue
      }
      payload.inputDeviceID = nil
      updated.steps[stepIndex].component = .inputCameraDevice(payload)
    }
    return updated
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
      automationNamed: { id in automations.first { $0.id == id } },
      imageForVision: imageForVision(_:),
      recordingPackageDirectory: { outputCoordinator.recordService?.packageDirectory },
      submitAutomation: { automation, source in
        submitAutomation(automation, source: source)
      },
      appendLog: appendLog(_:)
    )
  }

  private func imageForVision(_ vision: WorkspaceVisionDefinition) throws -> CIImage {
    let pixelBuffer: CVPixelBuffer?
    switch vision.source {
    case .currentProgramOutput:
      pixelBuffer = activeProgramRuntime.latestFrame()?.pixelBuffer
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

  private func runAutomation(_ automation: WorkspaceAutomationDefinition) {
    guard workspaceFeatureAvailability.supportsAutomation else { return }
    submitAutomation(automation, source: .normal)
  }

  private func synchronizeWorkspaceAutomations() {
    automationTasks.values.forEach { $0.cancel() }
    automationTasks.removeAll()
    guard workspaceFeatureAvailability.supportsAutomation else { return }
    let intervalAutomations = Dictionary(
      uniqueKeysWithValues: automations.compactMap {
        automation -> (String, WorkspaceAutomationDefinition)? in
        guard automation.isEnabled, case .interval = automation.trigger else { return nil }
        return (automation.id, automation)
      }
    )
    for (id, automation) in intervalAutomations {
      guard case .interval(let seconds) = automation.trigger else { continue }
      let timer = DispatchSource.makeTimerSource(queue: .main)
      timer.schedule(deadline: .now() + max(seconds, 0.1), repeating: max(seconds, 0.1))
      timer.setEventHandler {
        guard let current = automations.first(where: { $0.id == id }), current.isEnabled else {
          return
        }
        submitAutomation(current, source: .whenIdle)
      }
      timer.resume()
      automationTasks[id] = timer
    }
  }

  private func submitAutomation(
    _ automation: WorkspaceAutomationDefinition,
    source: SessionTaskSubmission
  ) {
    guard workspaceFeatureAvailability.supportsAutomation, automation.isEnabled,
      let sessionTaskQueue
    else { return }
    sessionTaskQueue.submit(
      key: SessionTaskKey("automation:\(automation.id)"), source: source
    ) { finish in
      { stopToken in
        Task { @MainActor in
          guard !stopToken.isStopRequested,
            automations.first(where: { $0.id == automation.id }) == automation
          else {
            finish()
            return
          }
          executeAutomationActions(automation, index: 0, stopToken: stopToken) {
            finish()
          }
        }
      }
    }
  }

  private func executeAutomationActions(
    _ automation: WorkspaceAutomationDefinition,
    index: Int,
    stopToken: StopToken,
    completion: @escaping @MainActor () -> Void
  ) {
    guard !stopToken.isStopRequested, index < automation.actions.count else {
      completion()
      return
    }
    let next = {
      executeAutomationActions(
        automation,
        index: index + 1,
        stopToken: stopToken,
        completion: completion
      )
    }
    switch automation.actions[index] {
    case .analyzeVision(let visionName):
      guard let vision = visions.first(where: { $0.name == visionName }) else {
        appendLog("Automation '\(automation.name)' references missing Vision \(visionName).")
        next()
        return
      }
      visionFeature.perform(vision, context: visionFeatureContext) { result in
        if case .failure(let error) = result {
          appendLog(
            "Automation '\(automation.name)' Vision action failed: \(errorDescription(error))")
        }
        next()
      }
    case .selectInputDevice(let inputDeviceName):
      if programInputDevices.contains(where: { $0.name == inputDeviceName }) {
        selectedSidebarItem = .inputDevice(inputDeviceName)
      } else {
        appendLog(
          "Automation '\(automation.name)' references missing Input Device \(inputDeviceName).")
      }
      next()
    }
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
    operationID: UUID
  ) async {
    guard let broadcastID = broadcast.id else {
      appendLog("YouTube broadcast is missing an ID.")
      markOutputSessionReadyToRestart(operationID: operationID)
      return
    }
    let outputMode = outputDestination.selectedCaptureOutputMode
    guard outputMode.streamsToYouTube else {
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
      let snapshot = activeProgramSnapshot()
      try await requestRequiredCaptureAccess(snapshot: snapshot)
      guard await synchronizeResourcesAfterRequiredCaptureAccess() else { return }
      let accessToken = try await authState.validAccessToken(
        configuration: oauthClientState.configuration
      )
      guard outputCoordinator.operationID == operationID,
        outputCoordinator.lifecycleState == .starting
      else {
        return
      }
      outputDestination.selectedExistingBroadcastID = broadcastID
      outputDestination.usesTemporaryStream = true

      let result = try await youtubeClientService.createDASHStream(
        accessToken: accessToken,
        request: YouTubeClientService.DASHStreamRequest(
          title: outputDestination.streamTitle,
          description: outputDestination.streamDescription,
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
        activeProgramRuntime: activeProgramRuntime,
        mediaHub: mediaHub
      )
      outputCoordinator.currentMediaHub = mediaHub
      outputCoordinator.currentSession = session
      createSessionTaskQueue()
      synchronizeVisionFeature()
      if outputMode.recordsLocally {
        localOutputStore.beginAccess()
      }
      let audioDeviceIDsByInputKey = mappedInputAudioDeviceIDs(
        composite: snapshot.composite,
        audioChannels: snapshot.audioChannels,
        workspaceInputDevices: programInputDevices,
        inputAudioDeviceMappings: inputAudioDeviceMappings
      )
      let audioDeviceNamesByInputKey = mappedInputAudioDeviceNames(
        composite: snapshot.composite,
        audioChannels: snapshot.audioChannels,
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
        snapshot: snapshot,
        continuityStore: dashStreamContinuityStore,
        boundary: youtubeOutputServiceProcess,
        eventHandler: { appendLog($0) },
        failureHandler: youtubeFailureHandler,
        readyHandler: { [weak session] in session?.requestVideoKeyFrame() })
      outputCoordinator.installYouTubeService(youtubeService, on: mediaHub)
      try await startAndWait(youtubeService: youtubeService)
      if outputMode.recordsLocally {
        let recordService = try ProgramRecordService(
          baseDirectory: localOutputStore.baseDirectory,
          recordID: ProgramRecordService.makeRecordID(),
          writerConfiguration: ProgramOutputEncodingConfiguration.make(snapshot: snapshot),
          audioTracks: ProgramRecordAudioTrack.make(
            deviceIDsByInputKey: audioDeviceIDsByInputKey,
            deviceNamesByInputKey: audioDeviceNamesByInputKey),
          failureHandler: recordFailureHandler)
        outputCoordinator.installRecordService(recordService, on: mediaHub)
        try await startAndWait(recordService: recordService)
        appendLog("Recording package started: \(recordService.packageDirectory.path)")
      }
      try await startAndWait(
        session: session,
        snapshot: snapshot,
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
      streamStatus = "Streaming to \(broadcast.snippet?.title ?? broadcastID)"
      captureStatus = outputMode.recordsLocally ? "Recording" : captureStatus
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
        ))
    }
  }

  private func stopOutputSession() {
    eventCoordinator.enqueue {
      guard outputCoordinator.lifecycleState != .idle else { return }
      outputDestination.selectedExistingBroadcastID = nil
      outputDestination.usesTemporaryStream = true
      let operationID = outputCoordinator.invalidateOperations(for: .stopping)
      let session = outputCoordinator.currentSession
      let outputMode =
        outputCoordinator.activeMode ?? outputDestination.selectedCaptureOutputMode
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
        return
      }
      streamStatus = "Stopped"
      captureStatus = "Idle"
      outputCoordinator.lifecycleState = .idle
      appendLog("Output stopped.")
    }
  }

  private func startOutputSession() {
    guard canStartOutputSession else { return }
    shutdownCoordinator.requestStart { _ in
      eventCoordinator.enqueue {
        guard canBeginOutputSession else { return }
        await beginOutputSession()
      }
    }
  }

  private func beginOutputSession() async {
    if outputCoordinator.lifecycleState != .readyToRestart {
      dashStreamContinuityStore.beginNewOutputSession()
    }
    let operationID = outputCoordinator.beginStarting()
    if outputDestination.isYouTubeEnabled {
      await startYouTubeOutput(operationID: operationID)
    } else if outputDestination.isRecordingEnabled {
      await startRecording(operationID: operationID)
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
    eventCoordinator.enqueue {
      await handleOutputFailure(failure)
    }
  }

  private func handleOutputFailure(_ failure: WorkspaceOutputFailure) async {
    guard outputCoordinator.operationID == failure.operationID,
      outputCoordinator.lifecycleState == .running
        || outputCoordinator.lifecycleState == .starting
    else { return }

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
    streamStatus = "Output failed"
    captureStatus = "Output failed"
    outputCoordinator.lifecycleState = .idle
    if let presentableError = failure.error as? any ErrorDialogPresentable {
      presentedErrorDialog = presentableError.errorDialogKind
    } else if !presentRecordingIDCollisionAlertIfNeeded(failure.error) {
      presentedErrorDialog = .outputSessionFailed
    }
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
    streamStatus = "Output failed"
    captureStatus = "Output failed"
    outputCoordinator.lifecycleState = .idle
    if let presentableError = error as? any ErrorDialogPresentable {
      presentedErrorDialog = presentableError.errorDialogKind
    } else {
      presentedErrorDialog = .outputSessionFailed
    }
  }

  private func stopAndWait(for session: ActiveProgramOutputSession) async {
    await withCheckedContinuation { continuation in
      session.stop { continuation.resume() }
    }
  }

  private func startAndWait(
    session: ActiveProgramOutputSession,
    snapshot: ProgramPreviewSnapshot,
    programPreferences: ProgramPreferences,
    audioDeviceIDsByInputKey: [String: String],
    eventHandler: @escaping @MainActor (String) -> Void,
    failureHandler: @escaping @MainActor (Error) -> Void
  ) async throws {
    try await withCheckedThrowingContinuation { continuation in
      session.start(
        snapshot: snapshot,
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

    eventCoordinator.enqueue {
      guard outputCoordinator.lifecycleState == .running,
        let session = outputCoordinator.currentSession
      else { return }
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
        return
      }
      streamStatus = "Paused"
      captureStatus = "Paused"
      outputCoordinator.lifecycleState = .readyToRestart
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

    return eventCoordinator.enqueue {
      guard outputCoordinator.lifecycleState == .running,
        let session = outputCoordinator.currentSession,
        let outputMode = outputCoordinator.activeMode
      else { return }
      if reason == .recordingSplit, !outputMode.recordsLocally { return }
      let operationID = outputCoordinator.invalidateOperations(for: .stopping)
      let selectedYouTubeBroadcastID = outputDestination.selectedExistingBroadcastID
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
        return
      }
      outputDestination.selectedCaptureOutputMode = outputMode
      outputDestination.selectedExistingBroadcastID = selectedYouTubeBroadcastID
      outputCoordinator.lifecycleState = .readyToRestart

      if reason == .manualReset {
        refreshCameras()
        _ = restartAudioMonitor()
      }

      shutdownCoordinator.requestStart { _ in
        eventCoordinator.enqueue {
          guard outputCoordinator.operationID == operationID,
            outputCoordinator.lifecycleState == .readyToRestart
          else {
            return
          }
          appendLog(reason.startingLogMessage)
          await beginOutputSession()
        }
      }
    }
  }

  private func startYouTubeOutput(operationID: UUID) async {
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
      await connectYouTubeBroadcast(broadcast, operationID: operationID)
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
        .first { $0.id == outputDestination.selectedExistingBroadcastID }?
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

  private func startRecording(operationID: UUID) async {
    guard outputDestination.selectedCaptureOutputMode == .record else {
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
      let snapshot = activeProgramSnapshot()
      try await requestRequiredCaptureAccess(snapshot: snapshot)
      guard await synchronizeResourcesAfterRequiredCaptureAccess() else { return }
      guard outputCoordinator.operationID == operationID,
        outputCoordinator.lifecycleState == .starting
      else {
        return
      }
      let mediaHub = ProgramOutputMediaHub()
      let session = ActiveProgramOutputSession(
        activeProgramRuntime: activeProgramRuntime,
        mediaHub: mediaHub
      )
      outputCoordinator.currentMediaHub = mediaHub
      outputCoordinator.currentSession = session
      createSessionTaskQueue()
      synchronizeVisionFeature()
      localOutputStore.beginAccess()
      let audioDeviceIDsByInputKey = mappedInputAudioDeviceIDs(
        composite: snapshot.composite,
        audioChannels: snapshot.audioChannels,
        workspaceInputDevices: programInputDevices,
        inputAudioDeviceMappings: inputAudioDeviceMappings
      )
      let audioDeviceNamesByInputKey = mappedInputAudioDeviceNames(
        composite: snapshot.composite,
        audioChannels: snapshot.audioChannels,
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
        baseDirectory: localOutputStore.baseDirectory,
        recordID: ProgramRecordService.makeRecordID(),
        writerConfiguration: ProgramOutputEncodingConfiguration.make(snapshot: snapshot),
        audioTracks: ProgramRecordAudioTrack.make(
          deviceIDsByInputKey: audioDeviceIDsByInputKey,
          deviceNamesByInputKey: audioDeviceNamesByInputKey),
        failureHandler: recordFailureHandler)
      outputCoordinator.installRecordService(recordService, on: mediaHub)
      try await startAndWait(recordService: recordService)
      appendLog("Recording package started: \(recordService.packageDirectory.path)")
      try await startAndWait(
        session: session,
        snapshot: snapshot,
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
      captureStatus = "Recording"
      appendLog("Recording started.")
    } catch {
      guard outputCoordinator.operationID == operationID else { return }
      await handleOutputFailure(
        WorkspaceOutputFailure(
          source: .startup,
          error: error,
          operationID: operationID,
          outputMode: .record
        ))
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

  private func activeProgramSnapshot() -> ProgramPreviewSnapshot {
    let size = (width: outputCanvas.canvasSize.width, height: outputCanvas.canvasSize.height)
    let composite = outputCanvas.applying(to: compositeProgramDefinition)
    let audioChannels = effectiveWorkspaceAudioChannels
    let cameraIDsByInputKey = mappedInputCameraDeviceIDs(
      composite: composite,
      workspaceInputDevices: programInputDevices,
      inputCameraDeviceMappings: inputCameraDeviceMappings
    )
    return ProgramPreviewSnapshot(
      composite: composite,
      audioChannels: audioChannels,
      canvasWidth: outputCanvas.canvasSize.width,
      canvasHeight: outputCanvas.canvasSize.height,
      outputWidth: size.width,
      outputHeight: size.height,
      frameRate: max(outputCanvas.programDefinitionFrameRate, 1),
      timeSeconds: Float(ProcessInfo.processInfo.systemUptime),
      programVideoPTSInputKey: programVideoPTSInputKey(
        composite: composite,
        cameraIDsByInputKey: cameraIDsByInputKey
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
      backgroundRemovalInputKeys: backgroundRemovalInputCameraDeviceKeys(
        composite: composite,
        workspaceInputDevices: programInputDevices
      ),
    )
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

  private func requestRequiredCaptureAccess(snapshot: ProgramPreviewSnapshot) async throws {
    if snapshot.composite.steps.contains(where: { $0.component.definition.usesInputCameraDevice }),
      await requestCaptureAccess(for: .video) == false
    {
      ldtxAppLogger.error("Camera access preflight failed before starting output.")
      throw CameraCaptureServiceError.cameraAccessDenied
    }

    if snapshot.audioChannels.contains(where: {
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
    captureStatus = result.cameras.isEmpty ? "No cameras" : "\(result.cameras.count) camera(s)"
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

  private func selectInputDevice(
    workspaceInputDeviceID: String,
    physicalDeviceID: String?
  ) -> AppAutomationCommandResult {
    guard canEditInputDevices else {
      return AppAutomationCommandResult(
        ok: false,
        message: "Pause output before changing Input Devices."
      )
    }
    guard
      let index = programInputDevices.firstIndex(where: {
        $0.id == workspaceInputDeviceID
      })
    else {
      return AppAutomationCommandResult(
        ok: false,
        message: "Program Input Device not found: \(workspaceInputDeviceID)"
      )
    }

    let inputDevice = programInputDevices[index]
    if let physicalDeviceID {
      let isAvailable: Bool
      switch inputDevice.kind {
      case .video:
        isAvailable = captureDeviceStore.containsCamera(id: physicalDeviceID)
      case .audio:
        isAvailable = captureDeviceStore.containsAudioDevice(id: physicalDeviceID)
      case .unspecified:
        isAvailable = false
      }

      guard isAvailable else {
        return AppAutomationCommandResult(
          ok: false,
          message:
            "Physical device is not available for \(inputDevice.kind.rawValue) input: \(physicalDeviceID)"
        )
      }
    }

    var updatedInputDevices = programInputDevices
    var updatedInputDevice = inputDevice
    updatedInputDevice.physicalDeviceID = physicalDeviceID
    updatedInputDevices[index] = updatedInputDevice
    programInputDevices = updatedInputDevices
    syncWorkspaceFromCurrentProgramLibrary()
    persistWorkspacePreferences()
    synchronizeInputDeviceCaptures()
    restartAudioMonitor()

    if let physicalDeviceID {
      appendLog(
        "Automation selected physical device \(CaptureDeviceStore.redactedDeviceID(physicalDeviceID)) for program input \(inputDevice.name)."
      )
      return AppAutomationCommandResult(
        ok: true,
        message: "Selected physical device for program input: \(inputDevice.name)"
      )
    }

    appendLog("Automation cleared physical device selection for program input \(inputDevice.name).")
    return AppAutomationCommandResult(
      ok: true,
      message: "Cleared physical device selection for program input: \(inputDevice.name)"
    )
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

  private func chooseLocalOutputDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.directoryURL = localOutputStore.baseDirectory
    panel.message = "Choose a folder for local DASH and MP4 output."
    panel.prompt = "Use Folder"

    guard panel.runModal() == .OK, let url = panel.url else { return }
    localOutputStore.selectBaseDirectory(url)
    persistOutputSettings()
    appendLog("Local output folder selected: \(url.path)")
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

private struct WorkspaceActions {
  var saveWorkspace: () -> Void
  var saveWorkspaceAs: () -> Void
}

private struct WorkspaceActionsKey: FocusedValueKey {
  typealias Value = WorkspaceActions
}

extension FocusedValues {
  fileprivate var workspaceActions: WorkspaceActions? {
    get { self[WorkspaceActionsKey.self] }
    set { self[WorkspaceActionsKey.self] = newValue }
  }
}

struct WorkspaceCommands: Commands {
  @FocusedValue(\.workspaceActions) private var workspaceActions

  private var diagnosticReportsDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
  }

  var body: some Commands {
    CommandGroup(replacing: .saveItem) {
      Button("Save") {
        workspaceActions?.saveWorkspace()
      }
      .keyboardShortcut("s", modifiers: .command)
      .disabled(workspaceActions == nil)

      Button("Save As...") {
        workspaceActions?.saveWorkspaceAs()
      }
      .keyboardShortcut("s", modifiers: [.command, .shift])
      .disabled(workspaceActions == nil)
    }

    CommandGroup(after: .help) {
      Button("Show Crash Reports in Finder") {
        NSWorkspace.shared.open(diagnosticReportsDirectory)
      }
    }
  }
}

private struct OutputSettingsAutomationError: Error {
  var message: String

  init(_ message: String) {
    self.message = message
  }
}

struct OutputToggleSelection: Equatable {
  var recordingEnabled: Bool
  var youtubeEnabled: Bool

  static func resolve(
    _ settings: Ldtx_Automation_V1_OutputSettings,
    current: Self
  ) throws -> Self {
    if settings.hasRecordingEnabled || settings.hasYoutubeEnabled {
      return Self(
        recordingEnabled: settings.hasRecordingEnabled
          ? settings.recordingEnabled : current.recordingEnabled,
        youtubeEnabled: settings.hasYoutubeEnabled
          ? settings.youtubeEnabled : current.youtubeEnabled)
    }
    guard settings.hasCaptureOutputMode else { return current }
    let legacyMode = try CaptureOutputMode(protoValue: settings.captureOutputMode)
    return Self(
      recordingEnabled: legacyMode.recordsLocally,
      youtubeEnabled: legacyMode.streamsToYouTube)
  }
}

extension CaptureOutputMode {
  fileprivate var protoValue: Ldtx_Automation_V1_CaptureOutputMode {
    switch self {
    case .youtube:
      .youtube
    case .record:
      .record
    case .youtubeAndRecord:
      .youtubeAndRecord
    }
  }

  fileprivate init(protoValue: Ldtx_Automation_V1_CaptureOutputMode) throws {
    switch protoValue {
    case .youtube:
      self = .youtube
    case .record:
      self = .record
    case .youtubeAndRecord:
      self = .youtubeAndRecord
    case .unspecified, .UNRECOGNIZED:
      throw OutputSettingsAutomationError(
        "captureOutputMode must be youtube, record, or youtubeAndRecord.")
    }
  }
}

extension YouTubeLiveStreamResolution {
  fileprivate var protoValue: Ldtx_Automation_V1_YouTubeLiveStreamResolution {
    switch self {
    case .p240:
      .p240
    case .p360:
      .p360
    case .p480:
      .p480
    case .p720:
      .p720
    case .p1080:
      .p1080
    case .p1440:
      .p1440
    case .p2160:
      .p2160
    }
  }

  fileprivate init(protoValue: Ldtx_Automation_V1_YouTubeLiveStreamResolution) throws {
    switch protoValue {
    case .p240:
      self = .p240
    case .p360:
      self = .p360
    case .p480:
      self = .p480
    case .p720:
      self = .p720
    case .p1080:
      self = .p1080
    case .p1440:
      self = .p1440
    case .p2160:
      self = .p2160
    case .unspecified, .UNRECOGNIZED:
      throw OutputSettingsAutomationError(
        "youtube.resolution must be p240, p360, p480, p720, p1080, p1440, or p2160.")
    }
  }
}

extension YouTubeLiveStreamFrameRate {
  fileprivate var protoValue: Ldtx_Automation_V1_YouTubeLiveStreamFrameRate {
    switch self {
    case .fps30:
      .fps30
    case .fps60:
      .fps60
    }
  }

  fileprivate init(protoValue: Ldtx_Automation_V1_YouTubeLiveStreamFrameRate) throws {
    switch protoValue {
    case .fps30:
      self = .fps30
    case .fps60:
      self = .fps60
    case .unspecified, .UNRECOGNIZED:
      throw OutputSettingsAutomationError("youtube.frameRate must be fps30 or fps60.")
    }
  }
}

private final class WorkspaceWindowCloseCoordinator: NSObject, NSWindowDelegate {
  typealias CloseOperation = @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void

  private var onClose: CloseOperation?
  private weak var observedWindow: NSWindow?
  private weak var previousDelegate: (any NSWindowDelegate)?
  private var closeIsAllowed = false
  private var closeIsPending = false
  private var installationTask: Task<Void, Never>?
  private weak var pendingWindow: NSWindow?

  @MainActor
  func beginInstalling(window: NSWindow?, onClose: @escaping CloseOperation) {
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
      self.install(window: window, onClose: onClose)
      self.pendingWindow = nil
      self.installationTask = nil
    }
  }

  @MainActor
  func install(window: NSWindow?, onClose: @escaping CloseOperation) {
    self.onClose = onClose
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
    ldtxAppLogger.notice("Installed Workspace window close gate")
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
  var refreshAutomationSelectedProgram: () -> Void
  var updateWorkspaceWindowDirtyState: () -> Void

  func body(content: Content) -> some View {
    content
      .task {
        performStartupTasks()
      }
      .onChange(of: selectedProgramName) { _, _ in
        refreshAutomationSelectedProgram()
      }
      .onChange(of: isWorkspaceDirty) { _, _ in
        updateWorkspaceWindowDirtyState()
      }
  }
}

private struct OutputSettingsPersistence: ViewModifier {
  var outputDestination: OutputDestinationModel
  var persistOutputSettings: () -> Void

  func body(content: Content) -> some View {
    content
      .onChange(of: outputDestination.selectedExistingBroadcastID) { _, _ in
        persistOutputSettings()
      }
      .onChange(of: outputToggleSelection) { _, _ in
        persistOutputSettings()
      }
      .onChange(of: outputDestination.streamTitle) { _, _ in
        persistOutputSettings()
      }
      .onChange(of: outputDestination.streamDescription) { _, _ in
        persistOutputSettings()
      }
      .onChange(of: outputDestination.usesTemporaryStream) { _, newValue in
        guard !newValue else { return }
        outputDestination.usesTemporaryStream = true
        persistOutputSettings()
      }
      .onChange(of: outputDestination.prefersColorPreview) { _, _ in
        persistOutputSettings()
      }
  }

  private var outputToggleSelection: OutputToggleSelection {
    OutputToggleSelection(
      recordingEnabled: outputDestination.isRecordingEnabled,
      youtubeEnabled: outputDestination.isYouTubeEnabled)
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
        programDefinitionChanged()
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
