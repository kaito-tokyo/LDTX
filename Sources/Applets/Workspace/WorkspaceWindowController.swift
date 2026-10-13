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
import LDTXProtos
import LDTXTaskQueue
import LDTXVision
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import LDTXYouTubeRTMPS
import Observation
import SwiftUI

@MainActor
public final class WorkspaceWindowController: NSWindowController,
  WorkspaceRuntimeActions
{
  private weak var hostedWindow: NSWindow?
  public override var window: NSWindow? {
    get { hostedWindow }
    set { hostedWindow = newValue }
  }
  private weak var workspaceDocument: (any WorkspaceDocumentContext)?
  public private(set) var contentController: WorkspaceViewController!
  public let stateService: WorkspaceStateService
  public let persistenceCoordinator: WorkspaceV4PersistenceCoordinator
  public let appletData: WorkspaceAppletData
  private let transientURL = URL(string: "ldtx-untitled://workspace/\(UUID())")!
  private var closeObserver: NSObjectProtocol?
  private weak var observedWindow: NSWindow?
  private var outputObservationTask: Task<Void, Never>?

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
    if let audioStatusObserver {
      NotificationCenter.default.removeObserver(audioStatusObserver)
      self.audioStatusObserver = nil
    }
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
      let names = stateService.workspaceDefinition.videoComponents.compactMap {
        component -> String? in
        guard case .vfxSource(let source) = component.videoComponent,
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

  public convenience init(
    document: WorkspaceDocument, appletData: WorkspaceAppletData = .shared
  ) {
    let stateService = document.stateService
    stateService.localStateURL = document.fileURL
    let persistence = WorkspaceV4PersistenceCoordinator(
      workspaceSnapshot: { stateService.editingWorkspace },
      replaceWorkspace: { stateService.replaceEditingWorkspace($0) }, url: document.fileURL,
      runtimeSnapshot: {
        var workspace = WorkspaceV4Bundle(
          definition: .init(), preferences: .init())
        workspace.preferences = stateService.workspacePreferences
        workspace.outputSettings = stateService.workspaceOutputSettings
        return workspace
      })
    if let workspace = document.workspaceSnapshot { persistence.adoptRuntimeWorkspace(workspace) }
    self.init(stateService: stateService, persistenceCoordinator: persistence,
      appletData: appletData, document: document)
    if let url = document.fileURL { adoptDocumentURL(url) }
    let changes = Observations { [weak document, weak stateService] in
      (document?.workspaceSnapshot, document?.fileURL,
        document?.lastContentModificationDate, stateService?.isOutputActive)
    }
    documentObservationTask = Task { @MainActor [weak self] in
      for await _ in changes {
        guard let self, !Task.isCancelled else { return }
        await self.refreshPersistedWorkspace()
      }
    }
  }

  public init(
    stateService: WorkspaceStateService,
    persistenceCoordinator: WorkspaceV4PersistenceCoordinator,
    appletData: WorkspaceAppletData,
    document: any WorkspaceDocumentContext
  ) {
    self.workspaceDocument = document
    self.stateService = stateService
    self.persistenceCoordinator = persistenceCoordinator
    self.appletData = appletData

    let captureSessionCoordinator = WorkspaceCaptureSessionCoordinator()
    let windowRuntime = WorkspaceWindowRuntime(
      persistence: persistenceCoordinator,
      captureSessionCoordinator: captureSessionCoordinator,
      physicalDeviceIDs: { appletData.physicalDeviceIDsByResourceInternalID },
      localState: {
        appletData.state(
          for: stateService.localStateURL,
          externalID: stateService.externalID.flatMap(UUID.init(uuidString:)))
      },
      selectProgram: { internalID in
        guard let url = stateService.localStateURL else { return }
        appletData.updateState(for: url) { $0.selectedProgramInternalID = internalID }
      })

    let recordingSession = WorkspaceV4RecordingSession(
      windowRuntime: windowRuntime,
      physicalDeviceIDs: { appletData.physicalDeviceIDsByResourceInternalID },
      localState: {
        appletData.state(
          for: stateService.localStateURL,
          externalID: stateService.externalID.flatMap(UUID.init(uuidString:)))
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
    let pairedPreview = ProgramCanvasPairedPreview(
      device: previewRenderer.device, delegate: previewRenderer,
      onSelectLandscape: { stateService.selectedAudioMix = .landscape },
      onSelectPortrait: { stateService.selectedAudioMix = .portrait })
    self.pairedPreview = pairedPreview
    self.windowRuntime = windowRuntime
    self.recordingSession = recordingSession
    self.audioCoordinator = audioCoordinator
    self.visionFeature = visionFeature
    self.lowFrequencyUpdateRegistry = lowFrequencyUpdateRegistry
    super.init(window: nil)
    weak var errorOwner: WorkspaceWindowController? = self
    let reportOperationError: (Error) -> Void = { errorOwner?.reportError($0) }
    let deviceRegistry = DeviceRegistryService()
    deviceRegistry.errorHandler = reportOperationError
    let content = WorkspaceViewController(
      document: document,
      appletData: appletData,
      stateService: stateService, peakMeter: audioCoordinator.peakMeter, reportError: reportOperationError,
      deviceRegistry: deviceRegistry,
      pairedPreview: pairedPreview,
      runtimeActions: {
        guard let owner = errorOwner, owner.shutdownTask == nil else { return nil }
        return owner
      }, runtimeWorkspace: { [weak runtime = windowRuntime] in runtime?.workspace })
    self.contentController = content
    content.didAttachWindow = { [weak self] window in self?.attachWindow(window) }
    appletData.registerTransientState(at: transientURL)
    if stateService.localStateURL == nil { stateService.localStateURL = transientURL }
    let outputChanges = Observations { stateService.isOutputActive }
    outputObservationTask = Task { @MainActor [weak self] in
      for await _ in outputChanges {
        guard let self, !Task.isCancelled else { return }
        Self.activeControllers.add(self)
        Self.updateRecordingDockBadge()
        visionFeature.outputStateDidChange()
      }
    }

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
    synchronizeAudioMonitor()

    let assignmentChanges = Observations { appletData.physicalDeviceIDsByResourceInternalID }
    deviceAssignmentsObservationTask = Task { @MainActor [weak self] in
      for await _ in assignmentChanges {
        guard !Task.isCancelled, let self, shutdownTask == nil else { return }
        synchronizeDeviceAssignments()
      }
    }

    let preferencesChanges = Observations { stateService.workspacePreferences }
    self.preferencesObservationTask = Task { @MainActor [weak self] in
      var isInitialValue = true
      for await _ in preferencesChanges {
        guard !Task.isCancelled, let self else { return }
        guard !isInitialValue else {
          isInitialValue = false
          continue
        }
        self.updateProgramRuntimes()
        self.updateMixPreferences()
        self.synchronizeAudioMonitor()
      }
    }

    recordingSession.stateDidChange = { [weak self] (state: WorkspaceRecordingState) in
      guard let self else { return }
      self.stateService.recordingState = state
      self.stateService.isOutputActive = state.isOutputActive
      self.stateService.isLocalRecording = self.recordingSession.isLocalRecording
      self.stateService.outputFailureMessage = {
        guard case .failed(let message) = state else { return nil }
        return message
      }()
    }
    stateService.recordingState = recordingSession.state
    stateService.isOutputActive = recordingSession.isRecording
    stateService.isLocalRecording = recordingSession.isLocalRecording
    if case .failed(let message) = recordingSession.state {
      stateService.outputFailureMessage = message
    }
    let ids = Set(
      windowRuntime.definition.visions.compactMap {
        $0.internalID
      })
    stateService.visionResults = stateService.visionResults.filter { ids.contains($0.key) }
    stateService.visionFailureMessages = stateService.visionFailureMessages.filter {
      ids.contains($0.key)
    }
    var context = windowRuntime.visionFeatureContext
    context.isOutputActive = { [weak stateService] in stateService?.isOutputActive ?? false }
    let reportResult = context.reportResult
    let reportFailure = context.reportFailure
    context.reportResult = { [weak stateService] id, output in
      reportResult(id, output)
      stateService?.visionResults[id] = output
      stateService?.visionFailureMessages.removeValue(forKey: id)
    }
    context.reportFailure = { [weak stateService] id, error in
      reportFailure(id, error)
      stateService?.visionResults.removeValue(forKey: id)
      stateService?.visionFailureMessages[id] = error.localizedDescription
    }
    visionFeature.synchronize(
      visions: windowRuntime.persistenceCoordinator.hasPersistedWorkspace ? windowRuntime.definition.visions : [],
      context: context)
    Self.activeControllers.add(self)
  }

  isolated deinit {
    if let audioStatusObserver { NotificationCenter.default.removeObserver(audioStatusObserver) }
    if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    documentObservationTask?.cancel()
    outputObservationTask?.cancel()
    deviceAssignmentsObservationTask?.cancel()
    preferencesObservationTask?.cancel()
    appletData.removeTransientState(at: transientURL)
  }

  private var documentObservationTask: Task<Void, Never>?

  // Runtime adoption is independent of Document's in-memory confirmation.
  func refreshPersistedWorkspace() async {
    guard let url = workspaceDocument?.fileURL else { return }
    await refreshPersistedWorkspace(at: url) { [weak self] in
      self?.workspaceDocument?.fileURL == url
    }
  }

  func refreshPersistedWorkspace(at url: URL, isCurrent: () -> Bool) async {
    guard shutdownTask == nil, !stateService.isOutputActive else { return }
    do {
      let workspace = try await Self.readPersistedWorkspace(at: url)
      guard shutdownTask == nil, !stateService.isOutputActive,
        isCurrent() else { return }
      guard workspace != windowRuntime.workspace else { return }
      persistenceCoordinator.adoptRuntimeWorkspace(workspace)
      confirmedContentsDidChange()
    } catch { reportError(error) }
  }

  @concurrent private static func readPersistedWorkspace(at url: URL) async throws -> WorkspaceV4Bundle {
    let coordinator = NSFileCoordinator()
    var coordinationError: NSError?
    var result: Result<WorkspaceV4Bundle, Error>?
    coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
      result = Result { try WorkspaceBundleReaderV4(at: source).read() }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw CocoaError(.fileReadUnknown) }
    return try result.get()
  }

  private static let activeControllers = NSHashTable<WorkspaceWindowController>.weakObjects()
  private static var pendingShutdownFailures: [String] = []

  static var hasPendingApplicationShutdown: Bool {
    !activeControllers.allObjects.isEmpty || !pendingShutdownFailures.isEmpty
  }

  /// Includes closed windows whose idempotent shutdown is still running.
  static func shutdownForApplicationTermination() async -> [String] {
    let controllers = activeControllers.allObjects
    await withTaskGroup(of: Void.self) { group in
      for controller in controllers {
        group.addTask { await controller.shutdown() }
      }
    }
    let failures = pendingShutdownFailures
    pendingShutdownFailures.removeAll()
    return failures
  }
  private static func updateRecordingDockBadge() {
    NSApplication.shared.dockTile.badgeLabel = activeControllers.allObjects.contains {
      $0.stateService.isOutputActive
    } ? "REC" : nil
  }

  func attachWindow(_ window: NSWindow?) {
    self.window = window
    guard let window, observedWindow !== window else { return }
    if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    observedWindow = window
    closeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { Task { await self?.shutdown() } }
    }
    presentNextError()
  }

  func adoptDocumentURL(_ url: URL) {
    if let previous = stateService.localStateURL, previous != url {
      appletData.copyState(from: previous, to: url)
    }
    stateService.localStateURL = url
    if let id = stateService.externalID.flatMap(UUID.init(uuidString:)) {
      appletData.migrateOutputData(from: url, externalID: id)
    }
    persistenceCoordinator.setDocumentURL(url)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  public func removeProgram(internalID: Int64) throws {
    guard shutdownTask == nil, !stateService.isOutputActive else {
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

  public func selectProgram(internalID: Int64) throws {
    guard let document = workspaceDocument else {
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
    guard stateService.workspaceDefinition.programs.contains(where: { $0.internalID == internalID }),
      let url = document.fileURL ?? stateService.localStateURL
    else {
      throw NSError(
        domain: "WorkspaceProgramSelection", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "The selected Program is unavailable."])
    }
    if !persistenceCoordinator.hasPersistedWorkspace {
      appletData.updateState(for: url) { $0.selectedProgramInternalID = internalID }
      return
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
    guard workspaceDocument?.fileURL != nil, persistenceCoordinator.hasPersistedWorkspace else {
      throw NSError(
        domain: "tokyo.kaito.ldtx.WorkspaceOutput", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Save the Workspace before starting output."])
    }
    windowRuntime.updateRuntimes()
    await recordingSession.start()
  }

  public func shutdown() async {
    if let shutdownTask {
      await shutdownTask.value
      return
    }
    closeErrorPresentation()
    if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    closeObserver = nil
    documentObservationTask?.cancel()
    outputObservationTask?.cancel()
    let task = Task { @MainActor in
      contentController.tearDown()
      pairedPreview.stop()
      previewRenderer.stop()
      deviceAssignmentsObservationTask?.cancel()
      preferencesObservationTask?.cancel()
      await visionFeature.stop()
      let priorFailure = stateService.outputFailureMessage
      await recordingSession.stop()
      if stateService.outputFailureMessage != priorFailure {
        shutdownFailureMessage = stateService.outputFailureMessage
      }
      await withCheckedContinuation { continuation in
        windowRuntime.captureSessionCoordinator.stopAndReset { continuation.resume() }
      }
      await audioCoordinator.stopAndReset()
      lowFrequencyUpdateRegistry.shutdown()
      windowRuntime.shutdown()
      if let shutdownFailureMessage { Self.pendingShutdownFailures.append(shutdownFailureMessage) }
      Self.activeControllers.remove(self)
      Self.updateRecordingDockBadge()
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
  public func classify(
    vision: Ldtx_Workspace_V4_LdtxSceneDetectorVision, modelURL: URL
  ) async throws -> String {
    guard windowRuntime.definition.visions.contains(where: {
      $0.vision == .ldtxSceneDetectorVision(vision)
    }), let url = windowRuntime.workspace.visionModels[vision.modelInternalID],
      url.standardizedFileURL == modelURL.standardizedFileURL
    else { throw CocoaError(.fileReadNoSuchFile) }
    let model = try await VisionImageClassifierService.loadModel(
      at: modelURL, noCompile: stateService.isOutputActive)
    return try await windowRuntime.classify(vision: vision, model: model)
  }

  public func synchronizeVision() {
    let ids = Set(
      windowRuntime.definition.visions.compactMap {
        $0.internalID
      })
    stateService.visionResults = stateService.visionResults.filter { ids.contains($0.key) }
    stateService.visionFailureMessages = stateService.visionFailureMessages.filter {
      ids.contains($0.key)
    }
    var context = windowRuntime.visionFeatureContext
    context.isOutputActive = { [weak stateService] in stateService?.isOutputActive ?? false }
    let reportResult = context.reportResult
    let reportFailure = context.reportFailure
    context.reportResult = { [weak stateService] id, output in
      reportResult(id, output)
      stateService?.visionResults[id] = output
      stateService?.visionFailureMessages.removeValue(forKey: id)
    }
    context.reportFailure = { [weak stateService] id, error in
      reportFailure(id, error)
      stateService?.visionResults.removeValue(forKey: id)
      stateService?.visionFailureMessages[id] = error.localizedDescription
    }
    visionFeature.synchronize(
      visions: windowRuntime.persistenceCoordinator.hasPersistedWorkspace ? windowRuntime.definition.visions : [],
      context: context)
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

  func confirmedContentsDidChange() {
    guard shutdownTask == nil else { return }
    synchronizeDeviceAssignments()
    synchronizeVision()
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
    let localState = stateService.localStateURL.map { appletData.state(for: $0) } ?? .init()
    let audioChannels = WorkspaceV4RenderGraph.audioChannels(windowRuntime.definition)
    let programInternalID = appletData.selectedProgram(
      in: windowRuntime.definition, for: stateService.localStateURL)?.internalID
    let projection = programInternalID.flatMap {
      try? windowRuntime.runtimeProjection(programInternalID: $0, target: .landscape)
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
    let portraitProjection = programInternalID.flatMap {
      try? windowRuntime.runtimeProjection(programInternalID: $0, target: .portrait)
    }
    audioCoordinator.peakMeter.updateMasterGains(
      landscapeChannels: audioChannels,
      portraitChannels: portraitProjection?.configuration.audioChannels ?? [],
      landscape: projection?.preferences ?? .init(),
      portrait: portraitProjection?.preferences ?? .init())
    let preferences = WorkspaceV4RenderGraph.monitorPreferences(
      definition: windowRuntime.definition, preferences: stateService.workspacePreferences,
      volumeDecibels: localState.monitorVolume ?? 0)
    _ = audioCoordinator.restart(
      audioChannels: audioChannels,
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
