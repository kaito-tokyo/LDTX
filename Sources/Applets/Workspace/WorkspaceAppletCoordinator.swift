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
import MetalKit
import Observation
import SwiftUI

@MainActor
public final class WorkspaceAppletCoordinator: WorkspaceRuntimeActions {
  // Reuse a live scene connection without creating a parent/child retain cycle.
  weak var documentConnection: WorkspaceDocumentConnection?
  public weak var window: NSWindow?
  private weak var workspaceDocument: (any WorkspaceDocumentContext)?
  let deviceRegistry = DeviceRegistryService()
  var peakMeter: ProgramAudioPeakMeter { audioCoordinator.peakMeter }
  private var inferenceTask: Task<Void, Never>?
  public let stateService: WorkspaceDocument
  public let persistenceCoordinator: WorkspaceV4PersistenceCoordinator
  public let appletData: WorkspaceAppletData
  private let transientURL = URL(string: "ldtx-untitled://workspace/\(UUID())")!
  private lazy var closeCoordinator = WorkspaceDocumentCloseCoordinator(
    validateClose: { [weak self] in try self?.validateCloseAdmission() },
    closeWorkspace: { [weak self] in
      guard let self else { return false }
      if case .succeeded = await self.closeWorkspace() { return true }
      return false
    }, reportError: { [weak self] in self?.reportError($0) })
  private var closeObserver: NSObjectProtocol?
  private weak var observedWindow: NSWindow?
  private var outputObservationTask: Task<Void, Never>?

  let pairedPreview: ProgramCanvasPairedPreview
  let previewRenderer: ProgramPairPreviewRenderer
  public var outputStateDidChange: (@MainActor () -> Void)?
  private var onShutdown: (@MainActor () -> Void)?
  let windowRuntime: WorkspaceWindowRuntime
  private let recordingSession: WorkspaceV4RecordingSession
  private let audioCoordinator: WorkspaceAudioCoordinator
  private let visionFeature: WorkspaceV4VisionFeature
  private var closeRequestTask: Task<WorkspaceCommandOutcome, Never>?
  public private(set) var shutdownFailureMessage: String?
  private var deviceAssignmentsObservationTask: Task<Void, Never>?
  private var preferencesObservationTask: Task<Void, Never>?

  private var audioStatusObserver: NSObjectProtocol?
  private var monitorFailureStatus: Int32?
  private var captureFailureIDs: Set<String> = []

  // Resource-operation migration uses this one per-Workspace command queue.
  // Each operation awaits its own resource completion before releasing admission.
  lazy var transactionalCommands = WorkspaceCommandQueue(
    label: "tokyo.kaito.ldtx.workspace.commands"
  ) { [weak self] notifications, cause in
    if let error = WorkspaceCommandFailureNotification.aggregatedError(
      notifications, causedBy: cause)
    {
      guard let self else { return }
      if stateService.isClosed {
        shutdownFailureMessage = [
          shutdownFailureMessage, error.localizedDescription,
          error.localizedFailureReason, error.localizedRecoverySuggestion,
        ]
        .compactMap { $0 }.joined(separator: "\n\n")
      } else {
        reportError(error)
      }
    }
  }

  private func commandFailure(_ command: WorkspaceTransactionalCommand, _ error: Error) -> NSError {
    return WorkspaceCommandFailureNotification.stalledCommands([command])[0]
      .error(causedBy: error as NSError)
  }

  func reportError(_ error: Error) {
    guard !stateService.isClosed else { return }
    stateService.operationErrors.append(error as NSError)
  }

  private func closeErrorPresentation() {
    stateService.operationErrors.removeAll()
    if let audioStatusObserver {
      NotificationCenter.default.removeObserver(audioStatusObserver)
      self.audioStatusObserver = nil
    }
  }

  public func runInference() {
    guard closeRequestTask == nil, !stateService.isClosed, inferenceTask == nil else { return }
    inferenceTask = Task { [self] in
      defer { inferenceTask = nil }
      await inferSelectedVision(
        stateService: stateService, document: workspaceDocument,
        runtimeWorkspace: { [weak self] in self?.windowRuntime.workspace })
    }
  }

  func updateMonitorFailure(_ status: Int32?) {
    guard !stateService.isClosed else { return }
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

  func updateCaptureFailures(_ failures: Set<String>, reportErrors: Bool = true) {
    guard !stateService.isClosed else { return }
    let newlyFailed = failures.subtracting(captureFailureIDs)
    captureFailureIDs = failures
    guard reportErrors, !newlyFailed.isEmpty else { return }
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

  /// Creates the Workspace's runtime resources once under the application owner.
  public convenience init(
    document: WorkspaceDocument, onShutdown: @escaping @MainActor () -> Void
  ) {
    let capture = WorkspaceCaptureSessionCoordinator()
    let backgroundRemoval: BackgroundRemovalPreprocessorFactory = { device, textureCache in
      BackgroundRemovalVideoInputPreprocessor(device: device, textureCache: textureCache)
    }
    let landscape = ProgramRuntime(
      captureSessionCoordinator: capture, backgroundRemovalPreprocessorFactory: backgroundRemoval)
    let portrait = ProgramRuntime(
      captureSessionCoordinator: capture, backgroundRemovalPreprocessorFactory: backgroundRemoval)
    let metalView = MTKView(frame: .zero, device: nil)
    metalView.isPaused = true
    self.init(
      document: document, landscapeRuntime: landscape, portraitRuntime: portrait,
      metalView: metalView, captureSessionCoordinator: capture,
      onShutdown: onShutdown)
  }

  public convenience init(
    document: WorkspaceDocument, appletData: WorkspaceAppletData = .shared,
    landscapeRuntime: ProgramRuntime, portraitRuntime: ProgramRuntime, metalView: MTKView,
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    onShutdown: @escaping @MainActor () -> Void = {}
  ) {
    let stateService = document.stateService
    stateService.localStateURL = document.fileURL
    let persistence = WorkspaceV4PersistenceCoordinator(
      workspaceSnapshot: { stateService.editingWorkspace },
      replaceWorkspace: { stateService.replaceEditingWorkspace($0, undoManager: nil) },
      url: document.fileURL,
      runtimeSnapshot: {
        var workspace = WorkspaceV4Bundle(
          definition: .init(), preferences: .init())
        workspace.preferences = stateService.workspacePreferences
        workspace.outputSettings = stateService.workspaceOutputSettings
        return workspace
      })
    var adoptionError: Error?
    if let workspace = document.workspaceSnapshot {
      do { try persistence.adoptRuntimeWorkspace(workspace) } catch { adoptionError = error }
    }
    self.init(
      stateService: stateService, persistenceCoordinator: persistence,
      appletData: appletData, document: document,
      landscapeRuntime: landscapeRuntime, portraitRuntime: portraitRuntime, metalView: metalView,
      captureSessionCoordinator: captureSessionCoordinator,
      onShutdown: onShutdown)
    if let adoptionError { reportError(commandFailure(.reconstructRuntime, adoptionError)) }
    if let url = document.fileURL { adoptDocumentURL(url) }
    let changes = Observations { [weak document, weak stateService] in
      (
        document?.workspaceSnapshot, document?.fileURL,
        document?.lastContentModificationDate, stateService?.isOutputActive
      )
    }
    documentObservationTask = Task { @MainActor [weak self] in
      for await _ in changes {
        guard let self, !Task.isCancelled else { return }
        await self.refreshPersistedWorkspace()
      }
    }
  }

  public init(
    stateService: WorkspaceDocument,
    persistenceCoordinator: WorkspaceV4PersistenceCoordinator,
    appletData: WorkspaceAppletData,
    document: any WorkspaceDocumentContext,
    landscapeRuntime: ProgramRuntime, portraitRuntime: ProgramRuntime, metalView: MTKView,
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    onShutdown: @escaping @MainActor () -> Void
  ) {
    self.onShutdown = onShutdown
    self.workspaceDocument = document
    self.stateService = stateService
    self.persistenceCoordinator = persistenceCoordinator
    self.appletData = appletData

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

    let backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory = {
      device, textureCache in
      BackgroundRemovalVideoInputPreprocessor(device: device, textureCache: textureCache)
    }
    windowRuntime.installComponentFrameRenderer(
      VideoComponentFrameRenderer(
        captureSessionCoordinator: captureSessionCoordinator,
        backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory))
    windowRuntime.installRuntimes(landscape: landscapeRuntime, portrait: portraitRuntime)
    windowRuntime.updateRuntimes()

    let previewRenderer = ProgramPairPreviewRenderer(
      landscapeRuntime: landscapeRuntime, portraitRuntime: portraitRuntime,
      landscapeSize: CGSize(width: 16, height: 9), portraitSize: CGSize(width: 9, height: 16),
      prefersColor: true)
    self.previewRenderer = previewRenderer
    metalView.device = previewRenderer.device
    let pairedPreview = ProgramCanvasPairedPreview(
      metalView: metalView, delegate: previewRenderer,
      onSelectLandscape: { stateService.selectedAudioMix = .landscape },
      onSelectPortrait: { stateService.selectedAudioMix = .portrait })
    self.pairedPreview = pairedPreview
    self.windowRuntime = windowRuntime
    self.recordingSession = recordingSession
    self.audioCoordinator = audioCoordinator
    self.visionFeature = visionFeature
    deviceRegistry.errorHandler = { [weak self] in self?.reportError($0) }
    pairedPreview.attachWindow = { [weak self] window in
      self?.attachWindow(window)
      guard let self else { return nil }
      return WorkspaceDocumentActions(
        stateService: self.stateService, window: window,
        onSaveSucceeded: { [weak self] in
          Task { await self?.refreshPersistedWorkspace(userInitiated: true) }
        })
    }
    appletData.registerTransientState(at: transientURL)
    if stateService.localStateURL == nil { stateService.localStateURL = transientURL }
    let outputChanges = Observations { stateService.isOutputActive }
    outputObservationTask = Task { @MainActor [weak self] in
      for await isOutputActive in outputChanges {
        guard let self, !Task.isCancelled else { return }
        outputStateDidChange?()
        visionFeature.outputStateDidChange()
        // Re-read current assignments and monitor output after leaving output.
        // Active-output notifications cannot admit resource work; this submits
        // fresh work without reopening Stall or replaying discarded commands.
        if !isOutputActive { synchronizeDeviceAssignments() }
      }
    }

    let engine = captureSessionCoordinator.audioEngine
    engine.setMonitorDeviceChangeHandler { [weak self] in
      Task { @MainActor [weak self] in self?.synchronizeDeviceAssignments() }
    }
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
    synchronizeDeviceAssignments()

    let assignmentChanges = Observations { appletData.physicalDeviceIDsByResourceInternalID }
    deviceAssignmentsObservationTask = Task { @MainActor [weak self] in
      for await _ in assignmentChanges {
        guard !Task.isCancelled, let self else { return }
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
        self.updateAudioMonitorValues()
      }
    }

    recordingSession.stateDidChange = { [weak self] (state: WorkspaceRecordingState) in
      guard let self else { return }
      self.stateService.recordingState = state
      self.stateService.isOutputActive = state.isOutputActive
      self.stateService.isLocalRecording = self.recordingSession.isLocalRecording
      self.visionFeature.outputStateDidChange()
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
    synchronizeVision()
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
  private var adoptedContentModificationDate: Date?

  // Runtime adoption is independent of Document's in-memory confirmation.
  func refreshPersistedWorkspace(userInitiated: Bool = false) async {
    guard let url = workspaceDocument?.fileURL else { return }
    await refreshPersistedWorkspace(at: url, userInitiated: userInitiated) { [weak self] in
      self?.workspaceDocument?.fileURL == url
    }
  }

  func refreshPersistedWorkspace(
    at url: URL, userInitiated: Bool = false,
    isCurrent: @escaping @MainActor () -> Bool
  ) async {
    guard closeRequestTask == nil, !stateService.isOutputActive,
      !transactionalCommands.contains(.startOutputSession)
    else { return }
    do {
      let workspace = try await Self.readPersistedWorkspace(at: url)
      guard !stateService.isOutputActive,
        isCurrent()
      else { return }
      let modificationDate = workspaceDocument?.lastContentModificationDate
      guard
        userInitiated || workspace != persistenceCoordinator.persistedWorkspace
          || modificationDate != adoptedContentModificationDate
      else { return }
      try WorkspaceV4PersistenceCoordinator.validateRuntimeWorkspace(workspace)
      if transactionalCommands.isStalled {
        guard userInitiated else { return }
        await transactionalCommands.resumeForNewRequests()
      }
      _ = await transactionalCommands.submit(
        .reconstructRuntime,
        validate: { [self] in
          guard closeRequestTask == nil, !stateService.isClosed, !stateService.isOutputActive,
            isCurrent()
          else {
            throw NSError(
              domain: "WorkspaceRuntime", code: 1,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "Runtime reconstruction is unavailable during output or closure."
              ])
          }
          try WorkspaceV4PersistenceCoordinator.validateRuntimeWorkspace(workspace)
        },
        operation: { [self] in
          guard !stateService.isOutputActive, isCurrent() else {
            throw NSError(
              domain: "WorkspaceRuntime", code: 1,
              userInfo: [NSLocalizedDescriptionKey: "The saved Workspace can no longer be applied."]
            )
          }
          guard
            userInitiated || workspace != persistenceCoordinator.persistedWorkspace
              || modificationDate != adoptedContentModificationDate
          else { return }
          try persistenceCoordinator.adoptRuntimeWorkspace(workspace)
          adoptedContentModificationDate = modificationDate
          (workspaceDocument as? WorkspaceDocument)?.confirmPersistedWorkspace(workspace)
          synchronizeVision()
          let cameraIDs = Set(CaptureSessionManager().availableCameras().map(\.id))
          var deviceError: Error?
          do { try await applyDeviceAssignment(availableCameraIDs: cameraIDs) } catch {
            deviceError = error
          }
          await visionFeature.prepareForOutput()
          if let deviceError { throw deviceError }
        })
    } catch {
      // Save As can replace an autosaved URL while its canonical read is in flight.
      // Discard failures from that obsolete location just like successful reads.
      guard isCurrent() else { return }
      reportError(commandFailure(.reconstructRuntime, error))
    }
  }

  @concurrent private static func readPersistedWorkspace(at url: URL) async throws
    -> WorkspaceV4Bundle
  {
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

  private var pendingShutdownFailure: String?

  func queueShutdownFailure(_ message: String) {
    pendingShutdownFailure = message
  }

  public func takeShutdownFailureForPresentation() -> String? {
    defer { pendingShutdownFailure = nil }
    return pendingShutdownFailure
  }

  func attachWindow(_ window: NSWindow?) {
    self.window = window
    closeCoordinator.attach(to: window)
    guard let window, observedWindow !== window else { return }
    if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    observedWindow = window
    closeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { Task { await self?.shutdown() } }
    }
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

  public func removeProgram(internalID: Int64, undoManager: UndoManager? = nil) throws {
    guard !stateService.isClosed, closeRequestTask == nil, !stateService.isOutputActive else {
      throw NSError(
        domain: "WorkspaceProgramDeletion", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "Programs cannot be deleted during output or shutdown."
        ])
    }
    try windowRuntime.removeProgram(internalID: internalID, applyRuntimeChanges: false) {
      workspace in
      self.stateService.replaceEditingWorkspace(workspace, undoManager: undoManager)
    }
  }

  @discardableResult
  public func selectProgram(internalID: Int64) throws -> Task<WorkspaceCommandQueue.Outcome, Never>
  {
    do {
      _ = try validatedProgramSelectionURL(internalID: internalID)
    } catch {
      throw commandFailure(.switchProgram, error)
    }
    return Task { @MainActor [self] in
      // A new explicit user request can reopen admission, but never reuses any
      // item invalidated by the previous Stall.
      if transactionalCommands.isStalled { await transactionalCommands.resumeForNewRequests() }
      return await transactionalCommands.submit(
        .switchProgram,
        validate: { [self] in _ = try validatedProgramSelectionURL(internalID: internalID) },
        operation: { [self] in try await applyProgramSelection(internalID: internalID) })
    }
  }

  public var programSelectionState: WorkspaceCommandState<Int64?> {
    let selected = stateService.localStateURL.flatMap {
      appletData.state(for: $0).selectedProgramInternalID
    }
    let programs = stateService.workspaceDefinition.programs
    return .init(
      value: (programs.first { $0.internalID == selected } ?? programs.first)?.internalID,
      retryNumber: transactionalCommands.retryNumber)
  }

  private func validatedProgramSelectionURL(internalID: Int64, admitted: Bool = false) throws -> URL
  {
    guard let document = workspaceDocument else {
      throw NSError(
        domain: "WorkspaceProgramSelection", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "The Workspace document is unavailable."])
    }
    guard admitted || closeRequestTask == nil, !stateService.isClosed,
      recordingSession.state.canSelectProgram
    else {
      throw NSError(
        domain: "WorkspaceProgramSelection", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "Program selection is unavailable during an output transition."
        ])
    }
    guard
      stateService.workspaceDefinition.programs.contains(where: { $0.internalID == internalID }),
      let url = document.fileURL ?? stateService.localStateURL
    else {
      throw NSError(
        domain: "WorkspaceProgramSelection", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "The selected Program is unavailable."])
    }
    if persistenceCoordinator.hasPersistedWorkspace,
      windowRuntime.definition.programs.contains(where: { $0.internalID == internalID })
    {
      for target in [WorkspaceCanvasTarget.landscape, .portrait] {
        let canvas = try WorkspaceProgramCanvasSnapshot(
          definition: windowRuntime.definition,
          preferences: windowRuntime.preferences, programInternalID: internalID, target: target)
        _ = try WorkspaceV4RenderGraph(
          definition: windowRuntime.definition, canvas: canvas,
          variableStore: windowRuntime.variableStore)
      }
    }
    return url
  }

  private func applyProgramSelection(internalID: Int64) async throws {
    let url = try validatedProgramSelectionURL(internalID: internalID, admitted: true)
    if !persistenceCoordinator.hasPersistedWorkspace
      || !windowRuntime.definition.programs.contains(where: { $0.internalID == internalID })
    {
      appletData.updateState(for: url) { $0.selectedProgramInternalID = internalID }
      return
    }
    let previousSelection = appletData.state(for: url).selectedProgramInternalID
    do {
      for target in [WorkspaceCanvasTarget.landscape, .portrait] {
        _ = try windowRuntime.runtimeProjection(programInternalID: internalID, target: target)
      }
      appletData.updateState(for: url) { $0.selectedProgramInternalID = internalID }
      windowRuntime.updateRuntimes()
      try await recordingSession.reconfigureProgramOutputAndWait()
      // Selection does not change the Workspace-wide device or Vision inventory.
      // Only the peak-meter projection changes; do not restart input resources.
      updatePeakMeterGains()
    } catch {
      // Repair only selection and its projections after application began.
      // Preserve edits and output failure/finalization; never restart output.
      appletData.updateState(for: url) { $0.selectedProgramInternalID = previousSelection }
      windowRuntime.updateRuntimes()
      throw error
    }
  }

  public func startOutput() async throws {
    try validateOutputStartAdmission()
    try await validateOutputWorkspace()
    if transactionalCommands.isStalled { await transactionalCommands.resumeForNewRequests() }
    var began = false
    let result = await transactionalCommands.submit(
      .startOutputSession,
      validate: { [self] in try validateOutputStartAdmission() },
      reconcile: { [self] in
        if began { _ = await recordingSession.stopWithResult() }
      },
      operation: { [self] in
        began = true
        stateService.recordingState = .starting
        stateService.isOutputActive = true
        defer {
          stateService.recordingState = recordingSession.state
          stateService.isOutputActive = recordingSession.state.isOutputActive
        }
        windowRuntime.updateRuntimes()
        await visionFeature.prepareForOutput()
        try await validateOutputWorkspace()
        try await recordingSession.startWithResult().get()
      })
    switch result {
    case .succeeded: return
    case .failed(let error), .rejected(let error): throw error
    }
  }

  private func validateOutputStartAdmission() throws {
    guard closeRequestTask == nil, !stateService.isClosed, !stateService.isOutputActive,
      recordingSession.state.canStart, !transactionalCommands.contains(.startOutputSession)
    else {
      throw NSError(
        domain: "WorkspaceOutput", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Output is already active or transitioning."])
    }
    let output = windowRuntime.workspace.outputSettings
    guard
      (output.recordingEnabled
        && (output.recordingSettings.recordsLandscape || output.recordingSettings.recordsPortrait))
        || output.youtubeEnabled
    else {
      throw NSError(
        domain: "WorkspaceOutput", code: 2,
        userInfo: [
          NSLocalizedDescriptionKey: "Enable recording or streaming before starting output."
        ])
    }
    guard
      let programID = appletData.selectedProgram(
        in: windowRuntime.definition, for: stateService.localStateURL)?.internalID
    else {
      throw NSError(
        domain: "WorkspaceOutput", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Select a Program before starting output."])
    }
    _ = try validatedProgramSelectionURL(internalID: programID)
  }

  func validateOutputWorkspace() async throws {
    guard let document = workspaceDocument, let url = document.fileURL,
      document.runtimeWorkspace != nil, persistenceCoordinator.hasPersistedWorkspace
    else {
      throw NSError(
        domain: "tokyo.kaito.ldtx.WorkspaceOutput", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Save the Workspace before starting output."])
    }
    let disk = try await Self.readPersistedWorkspace(at: url)
    let runtime = windowRuntime.workspace
    func matches(_ workspace: WorkspaceV4Bundle) -> Bool {
      workspace.definition == disk.definition && workspace.preferences == disk.preferences
        && workspace.outputSettings == disk.outputSettings
        && workspace.definitionExternalID == disk.definitionExternalID
        && workspace.preferencesExternalID == disk.preferencesExternalID
        && workspace.outputSettingsExternalID == disk.outputSettingsExternalID
        && Set(workspace.visionModels.keys) == Set(disk.visionModels.keys)
    }
    guard document.fileURL == url, let snapshot = document.runtimeWorkspace,
      matches(snapshot), matches(runtime)
    else {
      throw NSError(
        domain: "tokyo.kaito.ldtx.WorkspaceOutput", code: 2,
        userInfo: [
          NSLocalizedDescriptionKey:
            "The document, runtime, and saved Workspace must match before starting output. Wait for saving to finish or save the Workspace again."
        ])
    }
  }

  func validateCloseAdmission() throws {
    guard !stateService.isOutputActive, !recordingSession.state.isOutputActive,
      !transactionalCommands.contains(.startOutputSession)
    else {
      throw commandFailure(
        .closeWorkspace,
        NSError(
          domain: "WorkspaceClose", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Stop output before closing the Workspace."]))
    }
  }

  @discardableResult
  public func closeWorkspace() async -> WorkspaceCommandOutcome {
    if stateService.isClosed { return .succeeded }
    if let closeRequestTask { return await closeRequestTask.value }
    do { try validateCloseAdmission() } catch {
      reportError(error)
      return .rejected(error as NSError)
    }
    let task = Task { @MainActor [self] in
      if transactionalCommands.isStalled { await transactionalCommands.resumeForNewRequests() }
      let result = await transactionalCommands.submit(
        .closeWorkspace,
        validate: { [self] in try validateCloseAdmission() },
        operation: { [self] in try await drainWorkspaceResources() })
      if case .succeeded = result {
        stateService.isClosed = true
        documentConnection?.disconnect()
        closeErrorPresentation()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        closeCoordinator.detach()
        pairedPreview.metalView.removeFromSuperview()
        let release = onShutdown
        onShutdown = nil
        outputStateDidChange?()
        release?()
      }
      closeRequestTask = nil
      return result
    }
    closeRequestTask = task
    return await task.value
  }

  public func shutdown() async {
    _ = await closeWorkspace()
  }

  private func drainWorkspaceResources() async throws {
    documentObservationTask?.cancel()
    outputObservationTask?.cancel()
    deviceAssignmentsObservationTask?.cancel()
    preferencesObservationTask?.cancel()
    await inferenceTask?.value
    pairedPreview.stop()
    previewRenderer.stop()
    await previewRenderer.drainDrawing()
    await visionFeature.stop()
    let stopResult = await recordingSession.stopWithResult()
    await windowRuntime.shutdownAndWait()
    await withCheckedContinuation { continuation in
      windowRuntime.captureSessionCoordinator.stopAndReset { continuation.resume() }
    }
    await audioCoordinator.stopAndReset()
    guard windowRuntime.captureSessionCoordinator.isFullyStopped(),
      audioCoordinator.isFullyStopped()
    else {
      throw NSError(
        domain: "WorkspaceClose", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Workspace resources have not finished stopping."])
    }
    try stopResult.get()
  }

  public func pauseOutput() async {
    guard recordingSession.state == .recording else { return }
    if transactionalCommands.isStalled { await transactionalCommands.resumeForNewRequests() }
    _ = await transactionalCommands.submit(
      .stopOutputSession,
      validate: { [self] in try validateOutputStop() },
      operation: { [self] in try await recordingSession.pauseWithResult().get() })
  }

  public func stopOutput() async {
    if transactionalCommands.isStalled { await transactionalCommands.resumeForNewRequests() }
    _ = await transactionalCommands.submit(
      .stopOutputSession,
      validate: { [self] in try validateOutputStop() },
      operation: { [self] in try await recordingSession.stopWithResult().get() })
  }

  private func validateOutputStop() throws {
    guard closeRequestTask == nil, !stateService.isClosed else {
      throw NSError(
        domain: "WorkspaceOutput", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "The Workspace is closing."])
    }
  }

  public func updateMixPreferences() {
    recordingSession.updateMixPreferences()
  }

  public var streamDeckControls: WorkspaceOutputControls {
    .init(stateService: stateService, hasSavedURL: workspaceDocument?.fileURL != nil)
  }

  public func performStreamDeckAction(_ key: Int) async {
    let controls = streamDeckControls
    switch key {
    case 0 where controls.stopEnabled: await stopOutput()
    case 1 where controls.startPauseEnabled:
      await toggleOutput(stateService: stateService, document: workspaceDocument)
    case 2 where controls.screenshotEnabled:
      do { _ = try captureScreenshots() } catch { reportError(error) }
    default: break
    }
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

extension WorkspaceAppletCoordinator {
  public func classify(
    vision: Ldtx_Workspace_V4_LdtxSceneDetectorVision, modelURL: URL
  ) async throws -> String {
    let context = windowRuntime.visionFeatureContext
    let service: VisionImageClassifierService
    do {
      guard
        windowRuntime.definition.visions.contains(where: {
          $0.vision == .ldtxSceneDetectorVision(vision)
        }), let url = windowRuntime.workspace.visionModels[vision.modelInternalID],
        url.standardizedFileURL == modelURL.standardizedFileURL
      else { throw CocoaError(.fileReadNoSuchFile) }
      guard
        let preparedService = await visionFeature.classifierService(
          modelID: vision.modelInternalID, url: modelURL)
      else { throw CocoaError(.fileReadNoSuchFile) }
      guard context.isCurrent() else { throw CancellationError() }
      service = preparedService
    } catch {
      guard context.isCurrent() else { throw CancellationError() }
      if !(error is CancellationError) { context.reportFailure(vision.internalID, error) }
      throw error
    }
    return try await windowRuntime.classify(vision: vision, service: service)
  }

  private func synchronizeVision() {
    let ids = Set(
      windowRuntime.definition.visions.compactMap {
        $0.internalID
      })
    stateService.visionResults = stateService.visionResults.filter { ids.contains($0.key) }
    stateService.visionFailureMessages = stateService.visionFailureMessages.filter {
      ids.contains($0.key)
    }
    var context = windowRuntime.visionFeatureContext
    // The UI's starting status includes preparation. Vision must still prepare
    // models before the actual output service enters its starting state.
    context.isOutputActive = { [weak self] in self?.recordingSession.state.isOutputActive ?? false }
    context.reportModelPrepared = { [weak stateService] _ in
      stateService?.modelPreparationGeneration &+= 1
    }
    let reportPreparationRecovered = context.reportPreparationRecovered
    context.reportPreparationRecovered = { [weak stateService] id in
      reportPreparationRecovered(id)
      stateService?.visionFailureMessages.removeValue(forKey: id)
    }
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
      visions: windowRuntime.persistenceCoordinator.hasPersistedWorkspace
        ? windowRuntime.definition.visions : [],
      context: context)
  }

  private func synchronizeDeviceAssignments() {
    guard closeRequestTask == nil, !stateService.isClosed, !stateService.isOutputActive else {
      return
    }
    // Observation can update an accepting queue, but never resumes a stalled
    // queue or replays work merely because retryNumber changed.
    Task { @MainActor [weak self] in
      guard let self, !transactionalCommands.isStalled, !transactionalCommands.isRecovering else {
        return
      }
      let cameraIDs = Set(CaptureSessionManager().availableCameras().map(\.id))
      _ = await transactionalCommands.submit(
        .updateDeviceAssignment,
        validate: { [self] in try validateDeviceAssignment() },
        operation: { [self] in try await applyDeviceAssignment(availableCameraIDs: cameraIDs) })
    }
  }

  private func validateDeviceAssignment(admitted: Bool = false) throws {
    guard admitted || closeRequestTask == nil, !stateService.isClosed, !stateService.isOutputActive
    else {
      throw NSError(
        domain: "WorkspaceDeviceAssignment", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Pause output before changing device assignments."])
    }
  }

  @discardableResult
  public func updateDeviceAssignments(availableCameraIDs: Set<String>) throws -> Task<
    WorkspaceCommandOutcome, Never
  > {
    guard closeRequestTask == nil else { throw CocoaError(.userCancelled) }
    try validateDeviceAssignment()
    return Task { @MainActor [self] in
      if transactionalCommands.isStalled { await transactionalCommands.resumeForNewRequests() }
      return await transactionalCommands.submit(
        .updateDeviceAssignment,
        validate: { [self] in try validateDeviceAssignment() },
        operation: { [self] in
          try await applyDeviceAssignment(availableCameraIDs: availableCameraIDs)
        })
    }
  }

  private func applyDeviceAssignment(availableCameraIDs: Set<String>) async throws {
    try validateDeviceAssignment(admitted: true)
    windowRuntime.updateRuntimes()
    // Both configurations are captured before this operation first suspends.
    // Launch the monitor task, start Capture, and join both terminal results.
    let audio = makeAudioMonitorTask(reportErrors: false)
    let capture = await withCheckedContinuation { continuation in
      windowRuntime.synchronizeCaptureInputsReportingResult(availableCameraIDs: availableCameraIDs)
      {
        continuation.resume(returning: $0)
      }
    }
    let audioResult = await audio.value
    updateAudioMonitorValues()
    updateCaptureFailures(capture.unavailableOrFailedCameraIDs, reportErrors: false)
    if let error = capture.operationError { throw error }
    if let first = capture.failures.sorted(by: { $0.key < $1.key }).first {
      throw NSError(
        domain: first.value.domain, code: first.value.code,
        userInfo: [
          NSLocalizedDescriptionKey: "Camera assignment failed.",
          NSLocalizedFailureReasonErrorKey: capture.failures.keys.sorted().joined(separator: ", "),
          NSUnderlyingErrorKey: first.value,
        ])
    }
    try audioResult.get()
  }

  public func updateProgramRuntimes() {
    windowRuntime.updateRuntimes()
  }

  public func synchronizeCaptureInputs(
    availableCameraIDs: Set<String>,
    completionHandler: @escaping @Sendable (Set<String>) -> Void
  ) {
    Task { @MainActor [self] in
      do {
        _ = await (try updateDeviceAssignments(availableCameraIDs: availableCameraIDs)).value
      } catch {
        reportError(error)
      }
      completionHandler(captureFailureIDs)
    }
  }

  private func updatePeakMeterGains() {
    let audioChannels = WorkspaceV4RenderGraph.audioChannels(windowRuntime.definition)
    let programInternalID = appletData.selectedProgram(
      in: windowRuntime.definition, for: stateService.localStateURL)?.internalID
    let projection = programInternalID.flatMap {
      try? windowRuntime.runtimeProjection(programInternalID: $0, target: .landscape)
    }
    let portraitProjection = programInternalID.flatMap {
      try? windowRuntime.runtimeProjection(programInternalID: $0, target: .portrait)
    }
    audioCoordinator.peakMeter.updateMasterGains(
      landscapeChannels: audioChannels,
      portraitChannels: portraitProjection?.configuration.audioChannels ?? [],
      landscape: projection?.preferences ?? .init(),
      portrait: portraitProjection?.preferences ?? .init())
  }

  public func synchronizeAudioMonitor() {
    Task { @MainActor [weak self] in
      guard let self, closeRequestTask == nil else { return }
      do { try validateDeviceAssignment() } catch {
        reportError(error)
        return
      }
      if transactionalCommands.isStalled { await transactionalCommands.resumeForNewRequests() }
      _ = await transactionalCommands.submit(
        .updateDeviceAssignment,
        validate: { [self] in try validateDeviceAssignment() },
        operation: { [self] in
          try await makeAudioMonitorTask(reportErrors: false).value.get()
          updateAudioMonitorValues()
        })
    }
  }

  public func updateAudioMonitorValues() {
    guard !stateService.isClosed else { return }
    let local = stateService.localStateURL.map { appletData.state(for: $0) } ?? .init()
    let channels = WorkspaceV4RenderGraph.audioChannels(windowRuntime.definition)
    let preferences = WorkspaceV4RenderGraph.monitorPreferences(
      definition: windowRuntime.definition, preferences: stateService.workspacePreferences,
      volumeDecibels: local.monitorVolume ?? 0)
    audioCoordinator.monitor.updateValues(audioChannels: channels, preferences: preferences)
  }

  private func makeAudioMonitorTask(reportErrors: Bool) -> Task<Result<Void, NSError>, Never> {
    let localState = stateService.localStateURL.map { appletData.state(for: $0) } ?? .init()
    let audioChannels = WorkspaceV4RenderGraph.audioChannels(windowRuntime.definition)
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
    updatePeakMeterGains()
    let preferences = WorkspaceV4RenderGraph.monitorPreferences(
      definition: windowRuntime.definition, preferences: stateService.workspacePreferences,
      volumeDecibels: localState.monitorVolume ?? 0)
    return audioCoordinator.restart(
      audioChannels: audioChannels,
      inputAudioDeviceMappings: audioDeviceIDs,
      programPreferences: preferences,
      inputPassthroughChannelKeys: monitoredKeys,
      shouldRemainRunning: { true },
      failureHandler: { _ in },
      errorHandler: { [weak self] error in
        guard reportErrors, let self else { return }
        // Restart completion reports orchestration errors; hardware errors arrive via status.
        reportError(error)
      })
  }
}
