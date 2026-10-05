// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXBackgroundSegmentation
import LDTXCapture
import LDTXDeviceRegistry
import LDTXInternalProtocols
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspaceAppletInterface
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import LDTXYouTubeRTMPS
import Observation
import SwiftUI

@MainActor
public final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
  private let uiState: WorkspaceUIState
  private let appletData: WorkspaceAppletData
  private let dispatcher: WorkspaceDispatcher
  private let workspaceWindow: WorkspaceWindow

  let previewRenderer: ProgramPairPreviewRenderer
  let windowRuntime: WorkspaceWindowRuntime
  private let recordingSession: WorkspaceV4RecordingSession
  private let audioCoordinator: WorkspaceAudioCoordinator
  private let visionFeature: WorkspaceV4VisionFeature
  private let lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  private var shutdownTask: Task<Void, Never>?
  public private(set) var shutdownFailureMessage: String?
  private var deviceAssignmentsObservationTask: Task<Void, Never>?
  private var definitionObservationTask: Task<Void, Never>?
  private var preferencesObservationTask: Task<Void, Never>?

  public init(
    uiState: WorkspaceUIState,
    persistenceCoordinator: WorkspaceV4PersistenceCoordinator,
    appletData: WorkspaceAppletData,
    documentReference: DocumentReference
  ) {
    let url = uiState.localStateURL!
    self.uiState = uiState
    self.appletData = appletData
    self.dispatcher = WorkspaceDispatcher()

    let captureSessionCoordinator = WorkspaceCaptureSessionCoordinator()
    let windowRuntime = WorkspaceWindowRuntime(
      persistence: persistenceCoordinator,
      captureSessionCoordinator: captureSessionCoordinator,
      physicalDeviceIDs: { appletData.physicalDeviceIDsByResourceInternalID },
      localState: {
        guard let url = uiState.localStateURL else { return .init() }
        return appletData.state(for: url)
      },
      selectProgram: { internalID in
        guard let url = uiState.localStateURL else { return }
        appletData.updateState(for: url) { $0.selectedProgramInternalID = internalID }
      })

    let recordingSession = WorkspaceV4RecordingSession(
      windowRuntime: windowRuntime,
      physicalDeviceIDs: { appletData.physicalDeviceIDsByResourceInternalID },
      localState: {
        guard let url = uiState.localStateURL else { return .init() }
        return appletData.state(for: url)
      },
      streamKeyConfigurations: { try appletData.loadYouTubeStreamKeyConfigurations() })
    let audioCoordinator = WorkspaceAudioCoordinator(
      captureSessionCoordinator: captureSessionCoordinator)
    let visionFeature = WorkspaceV4VisionFeature()
    let lowFrequencyUpdateRegistry = LowFrequencyUpdateRegistry()

    let backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory = {
      device, textureCache in
      BackgroundRemovalVideoInputPreprocessor(device: device, textureCache: textureCache)
    }
    windowRuntime.installComponentFrameRenderer(
      VideoComponentFrameRenderer(
        captureSessionCoordinator: captureSessionCoordinator,
        backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory,
        lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry))
    let programRuntimeFactory:
      @MainActor (
        WorkspaceCaptureSessionCoordinator, ProgramPreferencesState, LowFrequencyUpdateRegistry
      ) -> ProgramRuntime = { coordinator, preferences, registry in
        ProgramRuntime(
          captureSessionCoordinator: coordinator,
          backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory,
          programPreferencesState: preferences,
          lowFrequencyUpdateRegistry: registry)
      }
    let landscapeRuntime = programRuntimeFactory(
      captureSessionCoordinator, ProgramPreferencesState(), lowFrequencyUpdateRegistry)
    let portraitRuntime = programRuntimeFactory(
      captureSessionCoordinator, ProgramPreferencesState(), lowFrequencyUpdateRegistry)
    windowRuntime.installRuntimes(landscape: landscapeRuntime, portrait: portraitRuntime)
    windowRuntime.updateRuntimes()

    let previewRenderer = ProgramPairPreviewRenderer(
      landscapeRuntime: landscapeRuntime, portraitRuntime: portraitRuntime,
      landscapeSize: CGSize(width: 16, height: 9), portraitSize: CGSize(width: 9, height: 16),
      prefersColor: true)
    self.previewRenderer = previewRenderer
    let window = WorkspaceWindow(
      url: url,
      deviceRegistry: DeviceRegistryService(),
      appletData: appletData,
      dispatcher: dispatcher,
      uiState: uiState, documentReference: documentReference,
      previewRenderer: previewRenderer,
      audioPeakMeter: audioCoordinator.peakMeter)
    self.workspaceWindow = window
    self.windowRuntime = windowRuntime
    self.recordingSession = recordingSession
    self.audioCoordinator = audioCoordinator
    self.visionFeature = visionFeature
    self.lowFrequencyUpdateRegistry = lowFrequencyUpdateRegistry
    super.init(window: window)

    previewRenderer.start()
    dispatcher.workspaceWindowController = self

    let assignmentChanges = Observations { appletData.physicalDeviceIDsByResourceInternalID }
    deviceAssignmentsObservationTask = Task { @MainActor [weak self] in
      for await _ in assignmentChanges {
        guard !Task.isCancelled, let self, shutdownTask == nil else { return }
        synchronizeDeviceAssignments()
      }
    }

    let definitionChanges = Observations { uiState.definition }
    self.definitionObservationTask = Task { @MainActor [weak windowRuntime] in
      var isInitialValue = true
      for await _ in definitionChanges {
        guard !Task.isCancelled, windowRuntime != nil else { return }
        guard !isInitialValue else {
          isInitialValue = false
          continue
        }
        dispatcher.updateProgramRuntimes()
      }
    }

    let preferencesChanges = Observations { uiState.preferences }
    self.preferencesObservationTask = Task { @MainActor [weak windowRuntime] in
      var isInitialValue = true
      for await _ in preferencesChanges {
        guard !Task.isCancelled, windowRuntime != nil else { return }
        guard !isInitialValue else {
          isInitialValue = false
          continue
        }
        dispatcher.updateProgramRuntimes()
      }
    }

    window.delegate = self
    window.identifier = NSUserInterfaceItemIdentifier(
      "WorkspaceV4.AppKit.v1." + UUID().uuidString)
    window.isRestorable = true
    window.setFrameAutosaveName("WorkspaceV4.AppKit.v1")

    recordingSession.stateDidChange = { [weak self] (state: WorkspaceRecordingState) in
      guard let self else { return }
      self.uiState.recordingState = state
      self.uiState.isOutputActive = state.isOutputActive
      self.uiState.isLocalRecording = self.recordingSession.isLocalRecording
      (self.window as? WorkspaceWindow)?.updateOutputToolbar()
      self.uiState.outputFailureMessage = {
        guard case .failed(let message) = state else { return nil }
        return message
      }()
    }
    uiState.recordingState = recordingSession.state
    uiState.isOutputActive = recordingSession.isRecording
    uiState.isLocalRecording = recordingSession.isLocalRecording
    if case .failed(let message) = recordingSession.state {
      uiState.outputFailureMessage = message
    }
    let ids = Set(
      windowRuntime.definition.visions.compactMap {
        try? WorkspaceV4IntegrityValidator.visionID($0)
      })
    uiState.visionResults = uiState.visionResults.filter { ids.contains($0.key) }
    uiState.visionFailureMessages = uiState.visionFailureMessages.filter { ids.contains($0.key) }
    var context = windowRuntime.visionFeatureContext
    let reportResult = context.reportResult
    let reportFailure = context.reportFailure
    context.reportResult = { [weak uiState] id, output in
      reportResult(id, output)
      uiState?.visionResults[id] = output
      uiState?.visionFailureMessages.removeValue(forKey: id)
    }
    context.reportFailure = { [weak uiState] id, error in
      reportFailure(id, error)
      uiState?.visionResults.removeValue(forKey: id)
      uiState?.visionFailureMessages[id] = error.localizedDescription
    }
    visionFeature.synchronize(visions: windowRuntime.definition.visions, context: context)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  func selectProgram(internalID: UInt64) throws {
    guard let document = document as? NSDocument else {
      throw NSError(
        domain: "WorkspaceProgramSelection", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "The Workspace document is unavailable."])
    }
    guard shutdownTask == nil, recordingSession.state.canSelectProgram else {
      throw NSError(
        domain: "WorkspaceProgramSelection", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "Program selection is unavailable during an output transition."
        ])
    }
    guard windowRuntime.definition.programs.contains(where: { $0.internalID == internalID }),
      let url = document.fileURL ?? uiState.localStateURL
    else {
      throw NSError(
        domain: "WorkspaceProgramSelection", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "The selected Program is unavailable."])
    }
    for target in [WorkspaceCanvasTarget.landscape, .portrait] {
      _ = try windowRuntime.runtimeProjection(programInternalID: internalID, target: target)
    }
    appletData.updateState(for: url) { $0.selectedProgramInternalID = internalID }
    windowRuntime.updateRuntimes()
    try recordingSession.reconfigureProgramOutput()
    synchronizeDeviceAssignments()
    synchronizeVision()
  }

  func startOutput() async throws {
    guard recordingSession.state.canStart else { return }
    guard document?.fileURL != nil else { throw CocoaError(.fileReadNoSuchFile) }
    windowRuntime.updateRuntimes()
    await recordingSession.start()
  }

  public func shutdown() async {
    if let shutdownTask {
      await shutdownTask.value
      return
    }
    let task = Task { @MainActor in
      workspaceWindow.stopContent()
      workspaceWindow.contentController.preview.stop()
      previewRenderer.stop()
      deviceAssignmentsObservationTask?.cancel()
      definitionObservationTask?.cancel()
      preferencesObservationTask?.cancel()
      visionFeature.stop()
      let priorFailure = uiState.outputFailureMessage
      await recordingSession.stop()
      if uiState.outputFailureMessage != priorFailure {
        shutdownFailureMessage = uiState.outputFailureMessage
      }
      await withCheckedContinuation { continuation in
        windowRuntime.captureSessionCoordinator.stopAndReset { continuation.resume() }
      }
      await audioCoordinator.stopAndReset()
      lowFrequencyUpdateRegistry.shutdown()
      windowRuntime.shutdown()
    }
    shutdownTask = task
    await task.value
  }

  func pauseOutput() async {
    await recordingSession.pause()
  }

  public func stopOutput() async {
    await recordingSession.stop()
  }

  func updateMixPreferences() {
    recordingSession.updateMixPreferences()
  }

  func captureScreenshots() throws -> [URL] {
    try recordingSession.captureScreenshots()
  }

  func openScreenshotsDirectory() {
    if let url = recordingSession.screenshotsDirectory {
      NSWorkspace.shared.open(url)
    }
  }
}

extension WorkspaceWindowController {
  func synchronizeVision() {
    let ids = Set(
      windowRuntime.definition.visions.compactMap {
        try? WorkspaceV4IntegrityValidator.visionID($0)
      })
    uiState.visionResults = uiState.visionResults.filter { ids.contains($0.key) }
    uiState.visionFailureMessages = uiState.visionFailureMessages.filter { ids.contains($0.key) }
    var context = windowRuntime.visionFeatureContext
    let reportResult = context.reportResult
    let reportFailure = context.reportFailure
    context.reportResult = { [weak uiState] id, output in
      reportResult(id, output)
      uiState?.visionResults[id] = output
      uiState?.visionFailureMessages.removeValue(forKey: id)
    }
    context.reportFailure = { [weak uiState] id, error in
      reportFailure(id, error)
      uiState?.visionResults.removeValue(forKey: id)
      uiState?.visionFailureMessages[id] = error.localizedDescription
    }
    visionFeature.synchronize(visions: windowRuntime.definition.visions, context: context)
  }

  private func synchronizeDeviceAssignments() {
    windowRuntime.updateRuntimes()
    let cameraIDs = Set(CaptureSessionManager().availableCameras().map(\.id))
    synchronizeCaptureInputs(availableCameraIDs: cameraIDs) { _ in }
    synchronizeAudioMonitor()
  }

  func updateProgramRuntimes() {
    windowRuntime.updateRuntimes()
  }

  func synchronizeCaptureInputs(
    availableCameraIDs: Set<String>,
    completionHandler: @escaping @Sendable (Set<String>) -> Void
  ) {
    windowRuntime.synchronizeCaptureInputs(
      availableCameraIDs: availableCameraIDs, completionHandler: completionHandler)
  }

  func synchronizeAudioMonitor() {
    let localState = uiState.localStateURL.map { appletData.state(for: $0) } ?? .init()
    guard
      let programInternalID = localState.selectedProgramInternalID
        ?? windowRuntime.definition.programs.first?.internalID,
      let projection = try? windowRuntime.runtimeProjection(
        programInternalID: programInternalID, target: .landscape)
    else {
      Task { await audioCoordinator.stopAndReset() }
      return
    }
    let audioDeviceIDs = Dictionary(
      uniqueKeysWithValues: windowRuntime.definition.audioDevices.compactMap {
        input -> (String, String)? in
        guard
          case .coreAudioDevice(let physicalID)? =
            appletData.physicalDeviceID(for: input.internalID)
        else { return nil }
        return ("v4-\(input.internalID)", physicalID)
      })
    let monitoredKeys = Set(
      windowRuntime.definition.audioDevices.compactMap { input -> String? in
        guard
          localState.monitorAudioInputDeviceInternalIDs.contains(input.internalID)
        else { return nil }
        return "v4-\(input.internalID)"
      })
    let portraitProjection = try? windowRuntime.runtimeProjection(
      programInternalID: programInternalID, target: .portrait)
    audioCoordinator.peakMeter.updateMasterGains(
      landscapeChannels: projection.configuration.audioChannels,
      portraitChannels: portraitProjection?.configuration.audioChannels ?? [],
      landscape: projection.preferences,
      portrait: portraitProjection?.preferences ?? .init())
    var preferences = projection.preferences
    preferences.masterVolume = ProgramPreferences.linearAudioChannelGain(
      fromDecibels: localState.monitorVolume ?? 0)
    _ = audioCoordinator.restart(
      audioChannels: projection.configuration.audioChannels,
      inputAudioDeviceMappings: audioDeviceIDs,
      programPreferences: preferences,
      inputPassthroughChannelKeys: monitoredKeys,
      shouldRemainRunning: { true },
      failureHandler: { _ in },
      errorHandler: { _ in })
  }
}
