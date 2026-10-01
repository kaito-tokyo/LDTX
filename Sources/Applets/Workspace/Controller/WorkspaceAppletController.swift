// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppInterface
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
public final class WorkspaceAppletController: NSWindowController, NSWindowDelegate {
  private let uiState: WorkspaceUIState
  private let appletData: WorkspaceAppletData
  private let dispatcher: WorkspaceDispatcher
  private let workspaceWindow: WorkspaceWindow

  private let windowRuntime: WorkspaceWindowRuntime
  private let recordingSession: WorkspaceV4RecordingSession
  private let audioCoordinator: WorkspaceAudioCoordinator
  private let visionFeature: WorkspaceV4VisionFeature
  private let lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  private var shutdownTask: Task<Void, Never>?
  public private(set) var shutdownFailureMessage: String?
  private var definitionObservationTask: Task<Void, Never>?
  private var preferencesObservationTask: Task<Void, Never>?
  private weak var recordingActivityReporter: (any WorkspaceRecordingActivityReporting)?
  private let recordingActivityID = UUID()
  private var hasReportedRecordingActivity = false

  public init(
    uiState: WorkspaceUIState,
    persistenceCoordinator: WorkspaceV4PersistenceCoordinator,
    appletData: WorkspaceAppletData,
    recordingActivityReporter: (any WorkspaceRecordingActivityReporting)? = nil
  ) {
    let url = uiState.localStateURL!
    self.uiState = uiState
    self.appletData = appletData
    self.dispatcher = WorkspaceDispatcher()
    self.recordingActivityReporter = recordingActivityReporter

    let captureSessionCoordinator = WorkspaceCaptureSessionCoordinator()
    let windowRuntime = WorkspaceWindowRuntime(
      persistence: persistenceCoordinator,
      captureSessionCoordinator: captureSessionCoordinator,
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
    windowRuntime.installRuntime(
      programRuntimeFactory(
        captureSessionCoordinator, ProgramPreferencesState(), lowFrequencyUpdateRegistry),
      role: .landscape)
    windowRuntime.installRuntime(
      programRuntimeFactory(
        captureSessionCoordinator, ProgramPreferencesState(), lowFrequencyUpdateRegistry),
      role: .portrait)
    windowRuntime.updateRuntimes()

    let window = WorkspaceWindow(
      url: url,
      deviceRegistry: DeviceRegistryService(),
      appletData: appletData,
      dispatcher: dispatcher,
      uiState: uiState)
    self.workspaceWindow = window
    self.windowRuntime = windowRuntime
    self.recordingSession = recordingSession
    self.audioCoordinator = audioCoordinator
    self.visionFeature = visionFeature
    self.lowFrequencyUpdateRegistry = lowFrequencyUpdateRegistry
    super.init(window: window)

    dispatcher.workspaceAppletController = self

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
      self.uiState.isOutputActive =
        switch state {
        case .starting, .recording, .stopping: true
        case .idle, .failed: false
        }
      self.uiState.isLocalRecording = self.recordingSession.isLocalRecording
      self.uiState.outputFailureMessage = {
        guard case .failed(let message) = state else { return nil }
        return message
      }()
      self.reportRecordingActivity(for: state)
    }
    uiState.isOutputActive = recordingSession.isRecording
    uiState.isLocalRecording = recordingSession.isLocalRecording
    if case .failed(let message) = recordingSession.state {
      uiState.outputFailureMessage = message
    }
    visionFeature.synchronize(
      visions: windowRuntime.definition.visions,
      context: windowRuntime.visionFeatureContext)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  func saveWorkspaceDefinition() async throws {
    guard let document = document as? WorkspaceDocument else { throw CocoaError(.fileWriteUnknown) }
    try await document.saveBeforeOutput()
  }

  func saveWorkspacePreferences() async throws {
    try await saveWorkspaceDefinition()
  }

  func startOutput() async throws {
    try await saveWorkspaceDefinition()
    windowRuntime.updateRuntimes()
    await recordingSession.start()
  }

  public func shutdown() async {
    if let shutdownTask {
      await shutdownTask.value
      return
    }
    let task = Task { @MainActor in
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

extension WorkspaceAppletController {
  private func reportRecordingActivity(for state: WorkspaceV4RecordingSession.State) {
    guard let recordingActivityReporter else { return }
    let isRecording: Bool
    switch state {
    case .starting, .recording, .stopping: isRecording = true
    case .idle, .failed: isRecording = false
    }
    guard isRecording != hasReportedRecordingActivity else { return }
    hasReportedRecordingActivity = isRecording
    if isRecording {
      recordingActivityReporter.workspaceRecordingDidStart(workspaceID: recordingActivityID)
    } else {
      recordingActivityReporter.workspaceRecordingDidStop(workspaceID: recordingActivityID)
    }
  }

  func synchronizeVision() {
    visionFeature.synchronize(
      visions: windowRuntime.definition.visions,
      context: windowRuntime.visionFeatureContext)
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
        programInternalID: programInternalID, role: .landscape)
    else {
      Task { await audioCoordinator.stopAndReset() }
      return
    }
    let audioDeviceIDs = Dictionary(
      uniqueKeysWithValues: windowRuntime.definition.inputDevices.compactMap {
        input -> (String, String)? in
        guard case .audioDevice(let device)? = input.definition,
          case .coreAudioDevice(let physicalID)? =
            localState
            .physicalDeviceIDsByInputDeviceInternalID[device.internalID]
        else { return nil }
        return ("v4-\(device.internalID)", physicalID)
      })
    let monitoredKeys = Set(
      windowRuntime.definition.inputDevices.compactMap { input -> String? in
        guard case .audioDevice(let device)? = input.definition,
          localState.monitorAudioInputDeviceInternalIDs.contains(device.internalID)
        else { return nil }
        return "v4-\(device.internalID)"
      })
    var preferences = projection.preferences
    preferences.masterVolume = ProgramPreferences.linearAudioChannelGain(
      fromDecibels: windowRuntime.preferences.monitorVolume)
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
