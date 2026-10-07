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
public final class WorkspaceWindowController: NSWindowController, NSWindowDelegate,
  WorkspaceRuntimeActions
{
  private let storeService: WorkspaceStoreService
  private let appletData: WorkspaceAppletData
  private let workspaceWindow: WorkspaceWindow

  let pairedPreview: ProgramCanvasPairedPreview
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

  private var pendingErrors: [Error] = []
  private var presentedError: NSError?
  private var errorPresentationClosed = false
  private var audioStatusObserver: NSObjectProtocol?
  private var monitorFailureStatus: Int32?
  private var captureFailureIDs: Set<String> = []

  func reportError(_ error: Error) {
    guard !errorPresentationClosed, shutdownTask == nil else { return }
    pendingErrors.append(error)
    presentNextError()
  }

  private func presentNextError() {
    guard !errorPresentationClosed, presentedError == nil, !pendingErrors.isEmpty,
      var host = window
    else { return }
    while let sheet = host.attachedSheet { host = sheet }
    let error = pendingErrors.removeFirst()
    presentedError = error as NSError
    presentError(
      error, modalFor: host, delegate: self,
      didPresent: #selector(errorDidPresent(_:contextInfo:)), contextInfo: nil)
  }

  public override func willPresentError(_ error: Error) -> Error {
    let error = super.willPresentError(error) as NSError
    guard let presentedError,
      error.domain == presentedError.domain, error.code == presentedError.code,
      let reason = error.localizedFailureReason
    else { return error }
    var info = error.userInfo
    info[NSLocalizedRecoverySuggestionErrorKey] =
      [reason, error.localizedRecoverySuggestion].compactMap { $0 }.joined(separator: "\n\n")
    return NSError(domain: error.domain, code: error.code, userInfo: info)
  }

  @objc private func errorDidPresent(_ didRecover: Bool, contextInfo: UnsafeMutableRawPointer?) {
    presentedError = nil
    Task { @MainActor [weak self] in self?.presentNextError() }
  }

  private func closeErrorPresentation() {
    errorPresentationClosed = true
    pendingErrors.removeAll()
    storeService.errorHandler = nil
    if let audioStatusObserver {
      NotificationCenter.default.removeObserver(audioStatusObserver)
      self.audioStatusObserver = nil
    }
  }

  public func windowWillClose(_ notification: Notification) {
    closeErrorPresentation()
  }

  func updateMonitorFailure(_ status: Int32?) {
    guard !errorPresentationClosed, shutdownTask == nil else { return }
    defer { monitorFailureStatus = status }
    guard let status, status != monitorFailureStatus else { return }
    reportError(
      NSError(
        domain: NSOSStatusErrorDomain, code: Int(status),
        userInfo: [
          NSLocalizedDescriptionKey: "Audio monitoring failed.",
          NSLocalizedFailureReasonErrorKey: "Core Audio error \(status).",
          NSLocalizedRecoverySuggestionErrorKey:
            "Check the monitor output device and its connection, then retry monitoring.",
        ]))
  }

  func updateCaptureFailures(_ failures: Set<String>) {
    guard !errorPresentationClosed, shutdownTask == nil else { return }
    let newlyFailed = failures.subtracting(captureFailureIDs)
    captureFailureIDs = failures
    guard !newlyFailed.isEmpty else { return }
    let descriptions = newlyFailed.sorted().map { uid in
      let names = storeService.definition.videoComponents.compactMap { component -> String? in
        guard case .vfxSource(let source) = component.definition,
          appletData.physicalDeviceID(for: source.internalID) == .avCaptureDevice(uniqueID: uid)
        else { return nil }
        return component.displayName
      }
      return names.isEmpty ? uid : names.joined(separator: ", ") + " (" + uid + ")"
    }
    reportError(
      NSError(
        domain: "tokyo.kaito.ldtx.WorkspaceCapture", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "Camera capture could not be started.",
          NSLocalizedFailureReasonErrorKey: descriptions.joined(separator: "\n"),
          NSLocalizedRecoverySuggestionErrorKey:
            "Check camera connections and permissions, then retry the assignment.",
        ]))
  }

  public init(
    storeService: WorkspaceStoreService,
    persistenceCoordinator: WorkspaceV4PersistenceCoordinator,
    appletData: WorkspaceAppletData,
    documentReference: DocumentReference
  ) {
    let url = storeService.localStateURL!
    self.storeService = storeService
    self.appletData = appletData
    storeService.appletData = appletData

    let captureSessionCoordinator = WorkspaceCaptureSessionCoordinator()
    let windowRuntime = WorkspaceWindowRuntime(
      persistence: persistenceCoordinator,
      captureSessionCoordinator: captureSessionCoordinator,
      physicalDeviceIDs: { appletData.physicalDeviceIDsByResourceInternalID },
      localState: {
        guard let url = storeService.localStateURL else { return .init() }
        return appletData.state(for: url)
      },
      selectProgram: { internalID in
        guard let url = storeService.localStateURL else { return }
        appletData.updateState(for: url) { $0.selectedProgramInternalID = internalID }
      })

    let recordingSession = WorkspaceV4RecordingSession(
      windowRuntime: windowRuntime,
      physicalDeviceIDs: { appletData.physicalDeviceIDsByResourceInternalID },
      localState: {
        guard let url = storeService.localStateURL else { return .init() }
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
    storeService.audioPeakMeter = audioCoordinator.peakMeter
    let pairedPreview = ProgramCanvasPairedPreview(
      device: previewRenderer.device, delegate: previewRenderer,
      onSelectLandscape: { storeService.selectedAudioMix = .landscape },
      onSelectPortrait: { storeService.selectedAudioMix = .portrait })
    self.pairedPreview = pairedPreview
    let deviceRegistry = DeviceRegistryService()
    deviceRegistry.errorHandler = { [weak storeService] error in storeService?.reportError(error) }
    let window = WorkspaceWindow(
      url: url,
      deviceRegistry: deviceRegistry,
      appletData: appletData,
      storeService: storeService, documentReference: documentReference,
      pairedPreview: pairedPreview)
    self.workspaceWindow = window
    self.windowRuntime = windowRuntime
    self.recordingSession = recordingSession
    self.audioCoordinator = audioCoordinator
    self.visionFeature = visionFeature
    self.lowFrequencyUpdateRegistry = lowFrequencyUpdateRegistry
    super.init(window: window)

    storeService.errorHandler = { [weak self] error in self?.reportError(error) }
    let engine = captureSessionCoordinator.audioEngine
    let engineID = engine.statusIdentifier
    audioStatusObserver = NotificationCenter.default.addObserver(
      forName: WorkspaceAudioEngine.statusDidChange, object: nil, queue: nil
    ) { [weak self] notification in
      guard notification.object as? UUID == engineID,
        let failures = notification.userInfo?["failures"] as? [String: Int32]
      else { return }
      Task { @MainActor [weak self] in self?.updateMonitorFailure(failures["Monitor"]) }
    }
    updateMonitorFailure(engine.currentFailures["Monitor"])
    previewRenderer.start()
    storeService.runtimeActions = self
    storeService.synchronizeAudioMonitor()

    let assignmentChanges = Observations { appletData.physicalDeviceIDsByResourceInternalID }
    deviceAssignmentsObservationTask = Task { @MainActor [weak self] in
      for await _ in assignmentChanges {
        guard !Task.isCancelled, let self, shutdownTask == nil else { return }
        synchronizeDeviceAssignments()
      }
    }

    let definitionChanges = Observations { storeService.definition }
    self.definitionObservationTask = Task { @MainActor [weak windowRuntime] in
      var isInitialValue = true
      for await _ in definitionChanges {
        guard !Task.isCancelled, windowRuntime != nil else { return }
        guard !isInitialValue else {
          isInitialValue = false
          continue
        }
        storeService.updateProgramRuntimes()
      }
    }

    let preferencesChanges = Observations { storeService.preferences }
    self.preferencesObservationTask = Task { @MainActor [weak windowRuntime] in
      var isInitialValue = true
      for await _ in preferencesChanges {
        guard !Task.isCancelled, windowRuntime != nil else { return }
        guard !isInitialValue else {
          isInitialValue = false
          continue
        }
        storeService.updateProgramRuntimes()
      }
    }

    window.delegate = self
    window.identifier = NSUserInterfaceItemIdentifier(
      "WorkspaceV4.AppKit.v1." + UUID().uuidString)
    window.isRestorable = true
    window.setFrameAutosaveName("WorkspaceV4.AppKit.v1")

    recordingSession.stateDidChange = { [weak self] (state: WorkspaceRecordingState) in
      guard let self else { return }
      self.storeService.recordingState = state
      self.storeService.isOutputActive = state.isOutputActive
      self.storeService.isLocalRecording = self.recordingSession.isLocalRecording
      (self.window as? WorkspaceWindow)?.updateOutputToolbar()
      self.storeService.outputFailureMessage = {
        guard case .failed(let message) = state else { return nil }
        return message
      }()
    }
    storeService.recordingState = recordingSession.state
    storeService.isOutputActive = recordingSession.isRecording
    storeService.isLocalRecording = recordingSession.isLocalRecording
    if case .failed(let message) = recordingSession.state {
      storeService.outputFailureMessage = message
    }
    let ids = Set(
      windowRuntime.definition.visions.compactMap {
        try? WorkspaceV4IntegrityValidator.visionID($0)
      })
    storeService.visionResults = storeService.visionResults.filter { ids.contains($0.key) }
    storeService.visionFailureMessages = storeService.visionFailureMessages.filter {
      ids.contains($0.key)
    }
    var context = windowRuntime.visionFeatureContext
    let reportResult = context.reportResult
    let reportFailure = context.reportFailure
    context.reportResult = { [weak storeService] id, output in
      reportResult(id, output)
      storeService?.visionResults[id] = output
      storeService?.visionFailureMessages.removeValue(forKey: id)
    }
    context.reportFailure = { [weak storeService] id, error in
      reportFailure(id, error)
      storeService?.visionResults.removeValue(forKey: id)
      storeService?.visionFailureMessages[id] = error.localizedDescription
    }
    visionFeature.synchronize(visions: windowRuntime.definition.visions, context: context)
  }

  isolated deinit {
    if let audioStatusObserver { NotificationCenter.default.removeObserver(audioStatusObserver) }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  public func removeProgram(internalID: UInt64) throws {
    guard shutdownTask == nil, !storeService.isOutputActive else {
      throw NSError(
        domain: "WorkspaceProgramDeletion", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "Programs cannot be deleted during output or shutdown."
        ])
    }
    try windowRuntime.removeProgram(internalID: internalID)
    synchronizeDeviceAssignments()
    synchronizeVision()
    synchronizeAudioMonitor()
  }

  public func selectProgram(internalID: UInt64) throws {
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
      let url = document.fileURL ?? storeService.localStateURL
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

  public func startOutput() async throws {
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
    closeErrorPresentation()
    let task = Task { @MainActor in
      storeService.runtimeActions = nil
      pairedPreview.stop()
      previewRenderer.stop()
      deviceAssignmentsObservationTask?.cancel()
      definitionObservationTask?.cancel()
      preferencesObservationTask?.cancel()
      visionFeature.stop()
      let priorFailure = storeService.outputFailureMessage
      await recordingSession.stop()
      if storeService.outputFailureMessage != priorFailure {
        shutdownFailureMessage = storeService.outputFailureMessage
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

  public func pauseOutput() async {
    await recordingSession.pause()
  }

  public func stopOutput() async {
    await recordingSession.stop()
  }

  public func updateMixPreferences() {
    recordingSession.updateMixPreferences()
  }

  public func captureScreenshots() throws -> [WorkspaceScreenshot] {
    try recordingSession.captureScreenshots()
  }

  public func openScreenshotsDirectory() {
    if let url = recordingSession.screenshotsDirectory {
      NSWorkspace.shared.open(url)
    }
  }
}

extension WorkspaceWindowController {
  public func synchronizeVision() {
    let ids = Set(
      windowRuntime.definition.visions.compactMap {
        try? WorkspaceV4IntegrityValidator.visionID($0)
      })
    storeService.visionResults = storeService.visionResults.filter { ids.contains($0.key) }
    storeService.visionFailureMessages = storeService.visionFailureMessages.filter {
      ids.contains($0.key)
    }
    var context = windowRuntime.visionFeatureContext
    let reportResult = context.reportResult
    let reportFailure = context.reportFailure
    context.reportResult = { [weak storeService] id, output in
      reportResult(id, output)
      storeService?.visionResults[id] = output
      storeService?.visionFailureMessages.removeValue(forKey: id)
    }
    context.reportFailure = { [weak storeService] id, error in
      reportFailure(id, error)
      storeService?.visionResults.removeValue(forKey: id)
      storeService?.visionFailureMessages[id] = error.localizedDescription
    }
    visionFeature.synchronize(visions: windowRuntime.definition.visions, context: context)
  }

  private func synchronizeDeviceAssignments() {
    windowRuntime.updateRuntimes()
    let cameraIDs = Set(CaptureSessionManager().availableCameras().map(\.id))
    synchronizeCaptureInputs(availableCameraIDs: cameraIDs) { _ in }
    synchronizeAudioMonitor()
  }

  public func updateProgramRuntimes() {
    windowRuntime.updateRuntimes()
  }

  public func synchronizeCaptureInputs(
    availableCameraIDs: Set<String>,
    completionHandler: @escaping @Sendable (Set<String>) -> Void
  ) {
    windowRuntime.synchronizeCaptureInputs(
      availableCameraIDs: availableCameraIDs,
      completionHandler: { [weak self] failures in
        Task { @MainActor [weak self] in self?.updateCaptureFailures(failures) }
        completionHandler(failures)
      })
  }

  public func synchronizeAudioMonitor() {
    let localState = storeService.localStateURL.map { appletData.state(for: $0) } ?? .init()
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
      errorHandler: { [weak self] error in
        guard let self else { return }
        // Restart completion reports orchestration errors; hardware errors arrive via status.
        reportError(error)
      })
  }
}
