// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFAudio
import AVFoundation
import CoreImage
import Foundation
import LDTXBackgroundSegmentation
import LDTXCapture
import LDTXCorelibs
import LDTXProgramRuntime
import LDTXRecording
import LDTXTaskQueue
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletStore
import LDTXYouTubeRTMPS
import OSLog
import Observation
import Synchronization

private enum WorkspaceV4RecordingSessionError: Error, LocalizedError {
  case microphoneAccessDenied

  var errorDescription: String? {
    "Microphone access was not granted."
  }
}

private final class VisionArchiveFailure: Sendable {
  let error = Mutex<(any Error)?>(nil)
}

/// Owns recording and streaming for one Version 4 Workspace Output.
@MainActor
@Observable
public final class WorkspaceV4RecordingSession {
  public typealias State = WorkspaceRecordingState

  private let windowRuntime: WorkspaceWindowRuntime
  private let physicalDeviceIDsProvider: () -> [Int64: WorkspacePhysicalDeviceID]
  private let localStateProvider: () -> WorkspaceLocalState
  private let streamKeyConfigurationsProvider: () throws -> [YouTubeRTMPSStreamKeyConfiguration]
  private var activeSession: ActiveDualProgramOutputSession?
  private var recordService: (any SessionRecordServicing)?
  @ObservationIgnored private var recordMediaCore = WorkspaceRecordMediaCore()
  @ObservationIgnored private var makeReplacementRecording: (() throws -> SessionRecordService)?
  @ObservationIgnored private var preparingRecordingPackages: Set<URL> = []
  @ObservationIgnored private var preparingRecordingFailures: [URL: NSError] = [:]
  @ObservationIgnored private var cutBoundaryWaiter: CheckedContinuation<UUID?, Never>?
  @ObservationIgnored private var cutDrainWaiters: [CheckedContinuation<Void, Never>] = []
  public private(set) var isCutPending = false
  private var isCutRecoveryPending = false
  @ObservationIgnored private var cutRecoveryID = UUID()
  @ObservationIgnored private var cutWasCancelled = false
  @ObservationIgnored private var cutBarrier: WorkspaceRecordCutBarrier?
  private var recordingAudioReady = false
  private let cutBoundaryTimeout: Duration
  private let cutFinalizationTimeout: Duration
  public private(set) var latestRecordingBundleURL: URL?
  private var youtubeRTMPSService: YouTubeRTMPSWorkspaceService?
  private(set) var sessionOutputSettings: Ldtx_Workspace_V4_WorkspaceOutputSettingsV4?
  private let visionArchiveQueue: DispatchQueue
  @ObservationIgnored private let visionArchiveFailure = VisionArchiveFailure()
  private var landscapeSubscription: ProgramOutputMediaHub.Subscription?
  private var portraitSubscription: ProgramOutputMediaHub.Subscription?
  private var landscapeHub: ProgramOutputMediaHub?
  private var portraitHub: ProgramOutputMediaHub?
  private var youtubeLandscapeSubscription: ProgramOutputMediaHub.Subscription?
  private var youtubePortraitSubscription: ProgramOutputMediaHub.Subscription?
  private var inputAudioSubscriptions: [WorkspaceCaptureSessionCoordinator.AudioSubscription] = []
  @ObservationIgnored private var stoppingTask: Task<Result<Void, NSError>, Never>?
  @ObservationIgnored private(set) var outputFailures = WorkspaceOutputFailures()
  @ObservationIgnored private var outputAttemptID = UUID()
  @ObservationIgnored private var hasCompletedOutputCleanup = false
  private var cleanupPriorFailureMessage: String?
  private static let logger = Logger(
    subsystem: "tokyo.kaito.ldtx", category: "WorkspaceOutputCleanup")
  private let screenCaptureService: ScreenCaptureService
  @ObservationIgnored private var pendingScreenshotCount = 0
  @ObservationIgnored private var pendingPackageScreenshotCount = 0
  @ObservationIgnored private var packageScreenshotDrainWaiters:
    [CheckedContinuation<Void, Never>] = []
  private let sleepInhibitor = OutputSleepInhibitor()
  @ObservationIgnored public var stateDidChange: (@MainActor (State) -> Void)?
  public var state: State {
    get { windowRuntime.recordingState }
    set {
      windowRuntime.setRecordingState(newValue)
      stateDidChange?(newValue)
    }
  }

  public init(
    windowRuntime: WorkspaceWindowRuntime,
    physicalDeviceIDs: @escaping () -> [Int64: WorkspacePhysicalDeviceID] = { [:] },
    localState: @escaping () -> WorkspaceLocalState = { .init() },
    screenCaptureService: ScreenCaptureService = ScreenCaptureService(),
    visionArchiveQueue: DispatchQueue = DispatchQueue(label: "tokyo.kaito.ldtx.v4-vision-archive"),
    cutBoundaryTimeout: Duration = .seconds(10),
    cutFinalizationTimeout: Duration = .seconds(30),
    streamKeyConfigurations: @escaping () throws -> [YouTubeRTMPSStreamKeyConfiguration] = { [] }
  ) {
    self.screenCaptureService = screenCaptureService
    self.windowRuntime = windowRuntime
    self.physicalDeviceIDsProvider = physicalDeviceIDs
    self.localStateProvider = localState
    self.visionArchiveQueue = visionArchiveQueue
    self.cutBoundaryTimeout = cutBoundaryTimeout
    self.cutFinalizationTimeout = cutFinalizationTimeout
    self.streamKeyConfigurationsProvider = streamKeyConfigurations
  }

  public var isRecording: Bool { state.isOutputActive }

  public func start() async { _ = await startWithResult() }

  public func startWithResult() async -> Result<Void, NSError> {
    guard state.canStart else {
      return .failure(
        NSError(
          domain: "WorkspaceOutput", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Output is already active or transitioning."]))
    }
    outputFailures = WorkspaceOutputFailures()
    outputAttemptID = UUID()
    hasCompletedOutputCleanup = false
    if isFailed {
      clearSessionReferences()
      state = .idle
    }
    guard let selectedProgramInternalID = selectedProgramInternalID else {
      state = .failed("Select a Program before starting recording.")
      return .failure(
        NSError(
          domain: "WorkspaceOutput", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Select a Program before starting recording."]))
    }
    let output = windowRuntime.workspace.outputSettings
    let recordsLandscape =
      (output.recordingEnabled == true) && (output.recordingSettings?.recordsLandscape == true)
    let recordsPortrait =
      (output.recordingEnabled == true) && (output.recordingSettings?.recordsPortrait == true)
    guard recordsLandscape || recordsPortrait || (output.youtubeEnabled == true) else {
      state = .failed("Enable recording or YouTube streaming in Output settings.")
      return .failure(
        NSError(
          domain: "WorkspaceOutput", code: 1,
          userInfo: [
            NSLocalizedDescriptionKey: "Enable recording or YouTube streaming in Output settings."
          ]))
    }
    guard let landscapeRuntime = windowRuntime.landscapeRuntime,
      let portraitRuntime = windowRuntime.portraitRuntime
    else {
      state = .failed("The selected Program runtime is unavailable.")
      return .failure(
        NSError(
          domain: "WorkspaceOutput", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "The selected Program runtime is unavailable."]))
    }
    guard let landscapeConfiguration = landscapeRuntime.programState.read({ $0 }),
      let portraitConfiguration = portraitRuntime.programState.read({ $0 })
    else {
      state = .failed("The selected Program has not been rendered yet.")
      return .failure(
        NSError(
          domain: "WorkspaceOutput", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "The selected Program has not been rendered yet."]))
    }

    sessionOutputSettings = output
    state = .starting
    sleepInhibitor.start()
    let baseDirectory = outputDirectory()
    let runsLandscape =
      recordsLandscape
      || ((output.youtubeEnabled == true)
        && (output.youtubeSettings?.ingestMode ?? .unspecified).usesLandscapeRTMPS)
    let runsPortrait =
      recordsPortrait
      || ((output.youtubeEnabled == true)
        && (output.youtubeSettings?.ingestMode ?? .unspecified).usesPortraitRTMPS)
    do {
      if recordsLandscape || recordsPortrait {
        try DefaultLocalOutputService(fileManager: .default).validateWritableBaseDirectory(
          baseDirectory)
      }
      try await requestRequiredCaptureAccess(
        configurations: [
          runsLandscape ? landscapeConfiguration : nil,
          runsPortrait ? portraitConfiguration : nil,
        ].compactMap { $0 }
      )
      guard state == .starting else { return await interruptedStartResult() }
    } catch {
      sleepInhibitor.stop()
      recordFailure(error, phase: .output)
      let primary = outputFailures.primary ?? (error as NSError)
      state = .failed(primary.localizedDescription)
      return .failure(primary)
    }

    let youtubeService: YouTubeRTMPSWorkspaceService?
    do {
      youtubeService =
        (output.youtubeEnabled == true) ? try makeYouTubeRTMPSService(for: output) : nil
    } catch {
      sleepInhibitor.stop()
      recordFailure(error, phase: .output)
      let primary = outputFailures.primary ?? (error as NSError)
      state = .failed(primary.localizedDescription)
      return .failure(primary)
    }
    let service: SessionRecordService?
    do {
      if recordsLandscape || recordsPortrait {
        let tracks = inputAudioTracks
        let makeService = { [weak self] in
          let recordID = SessionRecordService.makeRecordID()
          let packageURL = baseDirectory.appendingPathComponent(recordID, isDirectory: true)
            .appendingPathExtension(RecordingPackage.pathExtension)
          let service = try SessionRecordService(
            baseDirectory: baseDirectory,
            recordID: recordID,
            writerConfiguration: ProgramOutputEncodingConfiguration.make(
              configuration: landscapeConfiguration),
            portraitWriterConfiguration: ProgramOutputEncodingConfiguration.make(
              configuration: portraitConfiguration),
            audioTracks: tracks,
            recordsLandscape: recordsLandscape,
            recordsPortrait: recordsPortrait,
            customFields: output.recordingSettings?.customFields ?? [:],
            firstVideoAccepted: { [weak self] url in
              guard let self, self.recordService?.packageDirectory == url else { return }
              latestRecordingBundleURL = url
            },
            failureHandler: { [weak self] error in
              self?.recordingServiceDidFail(error, packageURL: packageURL)
            })
          self?.preparingRecordingPackages.insert(packageURL)
          return service
        }
        let recordService = try makeService()
        try recordService.start()
        prepareRecordingMedia(recordService, makeReplacement: makeService)
        adoptStartedRecordingService(recordService)
        service = recordService
      } else {
        service = nil
      }
    } catch {
      sleepInhibitor.stop()
      recordFailure(error, phase: .output)
      let primary = outputFailures.primary ?? (error as NSError)
      state = .failed(primary.localizedDescription)
      return .failure(primary)
    }

    let landscapeHub = ProgramOutputMediaHub()
    let portraitHub = ProgramOutputMediaHub()
    let outputSession = ActiveDualProgramOutputSession(
      landscapeRuntime: landscapeRuntime,
      portraitRuntime: portraitRuntime,
      captureSessionCoordinator: windowRuntime.captureSessionCoordinator,
      landscapeMediaHub: landscapeHub,
      portraitMediaHub: portraitHub,
      portraitPreferences: portraitPreferences(for: selectedProgramInternalID),
      portraitAudioDeviceIDsByInputKey: audioDeviceIDsByInputKey(),
      runsLandscape: runsLandscape,
      runsPortrait: runsPortrait)
    if let service {
      installRecordingSubscriptions(
        service: service, landscapeHub: landscapeHub, portraitHub: portraitHub,
        recordsLandscape: recordsLandscape, recordsPortrait: recordsPortrait)
    }
    if let youtubeService {
      installYouTubeRTMPSSubscriptions(
        youtubeService, landscapeHub: landscapeHub, portraitHub: portraitHub)
      youtubeRTMPSService = youtubeService
    }
    activeSession = outputSession
    self.landscapeHub = landscapeHub
    self.portraitHub = portraitHub

    do {
      if let service {
        try await installInputAudioSubscriptions(service: service, tracks: inputAudioTracks)
      }
      try await start(outputSession)
      if let youtubeRTMPSService {
        try await youtubeRTMPSService.waitUntilPublishing()
      }
      guard state == .starting else { return await interruptedStartResult() }
      state = .recording
      return .success(())
    } catch {
      await fail(error)
      return .failure(outputFailures.primary ?? (error as NSError))
    }
  }

  private func interruptedStartResult() async -> Result<Void, NSError> {
    _ = await stoppingTask?.value
    if let error = outputFailures.primary { return .failure(error) }
    let message = failureMessage ?? "Output startup did not complete."
    return .failure(
      NSError(
        domain: "WorkspaceOutput", code: 2,
        userInfo: [NSLocalizedDescriptionKey: message]))
  }

  func prepareRecordingMedia(
    _ service: any SessionRecordServicing,
    makeReplacement: @escaping () throws -> SessionRecordService
  ) {
    makeReplacementRecording = makeReplacement
    let core = WorkspaceRecordMediaCore()
    recordMediaCore = core
    recordingAudioReady = false
    isCutRecoveryPending = false
    core.install(service)
    core.setCallbacks(
      commitRequest: { [weak self] id in self?.completeCutBoundary(id) },
      eventHandler: { _ in },
      failureHandler: { [weak self] error in Task { @MainActor in await self?.fail(error) } },
      cutStateChanged: { [weak self] pending in
        if !pending { self?.completeCutBoundary(nil) }
      },
      audioFormatReadinessChanged: { [weak self, weak core] in
        guard let self, let core, self.recordMediaCore === core, let service = self.recordService
        else { return }
        self.recordingAudioReady = core.hasRequiredAudioFormatDescriptions(for: service)
      })
  }

  public var canCutRecording: Bool {
    // The first-video callback publishes this observable value when readiness changes.
    _ = latestRecordingBundleURL
    return state == .recording && !isCutPending && !isCutRecoveryPending
      && recordService?.hasAcceptedFirstVideo == true && recordingAudioReady
  }

  private func completeCutBoundary(_ id: UUID?) {
    guard id == nil || !isCutRecoveryPending else { return }
    let waiter = cutBoundaryWaiter
    cutBoundaryWaiter = nil
    waiter?.resume(returning: id)
  }

  /// Replace only the local package at a synchronized video boundary. Output
  /// capture, streaming, and input subscriptions remain active throughout.
  public func cutWithResult() async -> Result<Void, NSError> {
    guard canCutRecording, let previous = recordService, let makeReplacementRecording else {
      return .failure(
        NSError(
          domain: "WorkspaceRecordingCut", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Recording is not ready to cut."]))
    }
    isCutPending = true
    cutWasCancelled = false
    windowRuntime.visionArchivePackageURL = nil
    defer {
      if state == .recording, windowRuntime.visionArchivePackageURL == nil {
        windowRuntime.visionArchivePackageURL = recordService?.packageDirectory
      }
      cutBarrier?.cancel()
      cutBarrier = nil
      isCutPending = false
      let waiters = cutDrainWaiters
      cutDrainWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }
    let core = recordMediaCore
    let timeout = Task { @MainActor [weak self, cutBoundaryTimeout] in
      do { try await Task.sleep(for: cutBoundaryTimeout) } catch { return }
      guard !Task.isCancelled else { return }
      self?.cutBarrier?.cancel()
      self?.enqueueCutRollback(core)
      self?.completeCutBoundary(nil)
    }
    defer { timeout.cancel() }
    let boundaryID: UUID? = await withCheckedContinuation { continuation in
      cutBoundaryWaiter = continuation
      let hubs: [(ProgramOutputMediaHub, ProgramOutputMediaHub.Subscription)] = [
        landscapeHub.flatMap { hub in landscapeSubscription.map { (hub, $0) } },
        portraitHub.flatMap { hub in portraitSubscription.map { (hub, $0) } },
      ].compactMap { $0 }
      guard !hubs.isEmpty else {
        completeCutBoundary(nil)
        return
      }
      let barrier = WorkspaceRecordCutBarrier(arrivalCount: hubs.count) {
        core.enqueueCutRequest(for: previous)
      }
      cutBarrier = barrier
      for (hub, subscription) in hubs {
        if !hub.enqueueControl(subscription, operation: barrier.arriveAndWait) {
          barrier.cancel()
          completeCutBoundary(nil)
          break
        }
      }
    }
    timeout.cancel()
    guard let boundaryID, state == .recording else {
      enqueueCutRollback(core)
      if cutWasCancelled { return .success(()) }
      return .failure(
        NSError(
          domain: "WorkspaceRecordingCut", code: 2,
          userInfo: [NSLocalizedDescriptionKey: "The recording cut could not establish a boundary."]
        ))
    }
    var replacement: SessionRecordService?
    do {
      let next = try makeReplacementRecording()
      replacement = next
      try next.start()
      let commit = try await withCheckedThrowingContinuation { continuation in
        core.enqueueCommit(
          boundaryID: boundaryID, operationID: outputAttemptID, replacement: next
        ) { continuation.resume(with: $0) }
      }
      guard commit != nil else {
        throw NSError(
          domain: "WorkspaceRecordingCut", code: 3,
          userInfo: [NSLocalizedDescriptionKey: "The recording cut was interrupted."])
      }
      adoptStartedRecordingService(next)
      let result = await finishPreviousRecordingAfterCut(previous) { [self] in
        // All accepted old-package work is fenced before asking its writer to finalize.
        await drainPackageScreenshots()
        await withCheckedContinuation { continuation in
          visionArchiveQueue.async { continuation.resume() }
        }
        await core.waitForPendingOperations()
        await withCheckedContinuation { continuation in
          let deferred = core.deferFinalizationUntilInputAudioCallbacksDrain(for: previous) {
            continuation.resume()
          }
          if !deferred { continuation.resume() }
        }
      }
      if case .failed(let error) = result {
        recordFailure(error, phase: .recordingFinalization)
        return cutWasCancelled ? .success(()) : .failure(error as NSError)
      }
      return .success(())
    } catch {
      enqueueCutRollback(core)
      if let replacement {
        if !(error is WorkspaceRecordingPreparationAbandoned) {
          _ = await finishPreviousRecordingAfterCut(replacement, cancelling: true)
        }
        preparingRecordingPackages.remove(replacement.packageDirectory)
        preparingRecordingFailures.removeValue(forKey: replacement.packageDirectory)
      }
      return cutWasCancelled ? .success(()) : .failure(error as NSError)
    }
  }

  /// Keep Cut admission closed until rollback has returned the boundary media.
  private func enqueueCutRollback(_ core: WorkspaceRecordMediaCore) {
    isCutRecoveryPending = true
    let id = UUID()
    cutRecoveryID = id
    core.enqueueRollbackPendingCut { [weak self, weak core] in
      guard let self, let core, self.recordMediaCore === core, self.cutRecoveryID == id else {
        return
      }
      self.isCutRecoveryPending = false
    }
  }

  func finishPreviousRecordingAfterCut(
    _ service: any SessionRecordServicing,
    cancelling: Bool = false,
    beforeFinalization: (@MainActor () async -> Void)? = nil
  ) async -> SessionRecordFinalizationResult {
    await withCheckedContinuation { continuation in
      let race = RecordFinalizationRace(continuation: continuation)
      let timeout = Task { @MainActor [cutFinalizationTimeout] in
        do { try await Task.sleep(for: cutFinalizationTimeout) } catch { return }
        guard !Task.isCancelled else { return }
        race.finish(.failed(ProgramOutputMediaChannelError.drainTimedOut))
        service.abandonAfterMediaDrainTimeout()
      }
      race.installTimeoutTask(timeout)
      Task { @MainActor in
        await beforeFinalization?()
        guard !race.isFinished else { return }
        if cancelling {
          service.cancelBeforeFirstVideo { race.finish($0) }
          return
        }
        // Writer sealing can block synchronously, so keep it off MainActor and
        // within the same deadline as the finalization callback.
        DispatchQueue(label: "tokyo.kaito.ldtx.cut-finalization").async {
          service.sealInputAudio()
          Task { @MainActor in
            guard !race.isFinished else { return }
            service.finishAfterCut { race.finish($0) }
          }
        }
      }
    }
  }

  public func cancelPendingCut() {
    guard isCutPending else { return }
    cutWasCancelled = true
    cutBarrier?.cancel()
    enqueueCutRollback(recordMediaCore)
    completeCutBoundary(nil)
  }

  public func pause() async { _ = await pauseWithResult() }

  public func pauseWithResult() async -> Result<Void, NSError> {
    guard state == .recording else { return .success(()) }
    return await finishOutput(pausing: true)
  }

  public func stop() async { _ = await stopWithResult() }

  public func stopWithResult() async -> Result<Void, NSError> {
    if state == .paused {
      state = .idle
      return .success(())
    }
    let result = await finishOutput(pausing: false)
    // A stop that joined Pause must also leave the session idle.
    if state == .paused { state = .idle }
    return result
  }

  private func finishOutput(pausing: Bool) async -> Result<Void, NSError> {
    if let stoppingTask { return await stoppingTask.value }
    guard state == .starting || state == .recording || isFailed else { return .success(()) }
    // A previously reported failure must not make every later Workspace close fail.
    // The first cleanup already drained these resources and retained its diagnostics.
    if isFailed, hasCompletedOutputCleanup {
      return .success(())
    }
    return await beginFinishingOutput(pausing: pausing, priorFailure: nil).value
  }

  private func beginFinishingOutput(pausing: Bool, priorFailure: (any Error)?) -> Task<
    Result<Void, NSError>, Never
  > {
    // Lock out another request before the task reaches its first suspension.
    cleanupPriorFailureMessage = failureMessage
    if let priorFailure { recordFailure(priorFailure, phase: .output) }
    state = pausing ? .pausing : .stopping
    let task = Task { @MainActor in
      let result = await finishStopping(pausing: pausing)
      stoppingTask = nil
      return result
    }
    stoppingTask = task
    return task
  }

  private func finishStopping(pausing: Bool) async -> Result<Void, NSError> {
    cancelPendingCut()
    if isCutPending {
      await withCheckedContinuation { cutDrainWaiters.append($0) }
    }
    windowRuntime.visionArchivePackageURL = nil
    windowRuntime.visionArchiveHandler = nil
    windowRuntime.visionArchiveTimedHandler = nil
    windowRuntime.visionArchiveTimelineProvider = nil
    cleanupPhase("active-output", completed: false)
    if let activeSession { await stop(activeSession) }
    cleanupPhase("active-output", completed: true)
    cleanupPhase("subscriptions", completed: false)
    await unsubscribeAndDrain()
    recordMediaCore.enqueueRollbackPendingCut()
    if case .failure(let error) = await recordMediaCore.closeAndDrain() {
      recordFailure(error, phase: .output)
      recordService?.abandonAfterMediaDrainTimeout()
    }
    cleanupPhase("subscriptions", completed: true)
    cleanupPhase("vision-archive", completed: false)
    await withCheckedContinuation { continuation in
      visionArchiveQueue.async { continuation.resume() }
    }
    if let error = visionArchiveFailure.error.withLock({ error in
      defer { error = nil }
      return error
    }) {
      recordFailure(error, phase: .visionArchive)
    }
    cleanupPhase("vision-archive", completed: true)
    cleanupPhase("package-screenshots", completed: false)
    await drainPackageScreenshots()
    cleanupPhase("package-screenshots", completed: true)
    if let recordService {
      cleanupPhase("recording", completed: false)
      await finalize(recordService)
      cleanupPhase("recording", completed: true)
    }
    if let youtubeRTMPSService {
      await finishYouTubeOutput { await youtubeRTMPSService.finish() }
    }
    clearSessionReferences()
    sleepInhibitor.stop()
    hasCompletedOutputCleanup = true
    state =
      (outputFailures.primary?.localizedDescription ?? cleanupPriorFailureMessage)
      .map(State.failed) ?? (pausing ? .paused : .idle)
    cleanupPriorFailureMessage = nil
    return outputFailures.primary.map { .failure($0) } ?? .success(())
  }

  public func reconfigureProgramOutput() throws {
    guard state == .recording, let activeSession, let programID = selectedProgramInternalID else {
      return
    }
    guard
      activeSession.reconfigureAudio(
        landscapePreferences: preferences(
          windowRuntime.preferences.landscapeProgramPreferences[programID] ?? .init()),
        portraitPreferences: portraitPreferences(for: programID),
        audioDeviceIDsByInputKey: audioDeviceIDsByInputKey())
    else {
      let error = NSError(
        domain: "WorkspaceProgramSelection", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "The selected Program audio could not be applied."])
      _ = beginFinishingOutput(pausing: false, priorFailure: error)
      throw error
    }
  }

  public func reconfigureProgramOutputAndWait() async throws {
    // Native media faults can already be draining the session. A Program
    // switch must join that cleanup even when there is no live mixer to update.
    _ = await stoppingTask?.value
    guard state == .recording, let activeSession, let programID = selectedProgramInternalID else {
      return
    }
    do {
      try await activeSession.reconfigureAudioAndWait(
        landscapePreferences: preferences(
          windowRuntime.preferences.landscapeProgramPreferences[programID] ?? .init()),
        portraitPreferences: portraitPreferences(for: programID),
        audioDeviceIDsByInputKey: audioDeviceIDsByInputKey())
      _ = await stoppingTask?.value
      if case .failed(let message) = state {
        throw NSError(
          domain: "WorkspaceProgramSelection", code: 4,
          userInfo: [NSLocalizedDescriptionKey: message])
      }
    } catch {
      await fail(error)
      throw error
    }
  }

  public func updateMixPreferences() {
    guard let activeSession, let programID = selectedProgramInternalID else {
      return
    }
    activeSession.updateProgramPreferences(
      preferences(windowRuntime.preferences.landscapeProgramPreferences[programID] ?? .init()))
    activeSession.updatePortraitProgramPreferences(portraitPreferences(for: programID))
  }

  public func captureScreenshots() async throws -> [WorkspaceScreenshot] {
    var sources: [ScreenCaptureSource] = []
    if let frame = windowRuntime.landscapeRuntime?.latestFrame() {
      sources.append(
        ScreenCaptureSource(
          name: "Landscape", pixelBuffer: frame.pixelBuffer, programCanvas: .landscape))
    }
    if let frame = windowRuntime.portraitRuntime?.latestFrame() {
      sources.append(
        ScreenCaptureSource(
          name: "Portrait", pixelBuffer: frame.pixelBuffer, programCanvas: .portrait))
    }
    for wrapper in windowRuntime.definition.videoComponents {
      guard case .vfxSource(let input)? = wrapper.videoComponent, let inputID = input.internalID,
        let name = input.displayName,
        case .avCaptureDevice(let cameraID)? = physicalDeviceIDsProvider()[inputID],
        let frame = windowRuntime.captureSessionCoordinator.latestFrame(forCameraID: cameraID)
      else { continue }
      sources.append(ScreenCaptureSource(name: name, pixelBuffer: frame.pixelBuffer))
    }
    return try await captureScreenshots(
      sources: sources, capturedAt: Date(),
      globalDirectory: applicationOutputPreferences.screenshotsDirectory)
  }

  func captureScreenshots(
    sources: [ScreenCaptureSource], capturedAt: Date, globalDirectory: URL
  ) async throws -> [WorkspaceScreenshot] {
    // Bound retained frame copies to one active capture and one waiting capture.
    guard pendingScreenshotCount < 2 else { throw ScreenCaptureError.captureBusy }
    pendingScreenshotCount += 1
    defer { pendingScreenshotCount -= 1 }
    let snapshots = try sources.map { source in
      try screenCaptureService.snapshot(
        pixelBuffer: source.pixelBuffer, name: source.name, programCanvas: source.programCanvas)
    }
    var directories = [globalDirectory]
    var copiesToPackage = false
    // Snapshot and admission share MainActor with pause/stop. Finalization drains
    // accepted copies; later requests see the transition state and save globally.
    if state == .recording, let recordService,
      recordService.hasAcceptedFirstVideo,
      recordService.recordingTimelineMilliseconds() != nil
    {
      directories.append(recordService.packageDirectory.appendingPathComponent("Screenshots"))
      copiesToPackage = true
      pendingPackageScreenshotCount += 1
    }
    defer {
      if copiesToPackage {
        pendingPackageScreenshotCount -= 1
        if pendingPackageScreenshotCount == 0 {
          let waiters = packageScreenshotDrainWaiters
          packageScreenshotDrainWaiters.removeAll()
          for waiter in waiters { waiter.resume() }
        }
      }
    }
    return try await screenCaptureService.enqueueCapture(
      sources: snapshots, capturedAt: capturedAt, outputDirectories: directories
    ).screenshots.filter {
      $0.url.deletingLastPathComponent().standardizedFileURL == globalDirectory.standardizedFileURL
    }
  }

  // The output transition has closed package admission. Only this session's
  // package copies enter this scope; their normal shared-writer FIFO wait remains.
  private func drainPackageScreenshots() async {
    guard pendingPackageScreenshotCount > 0 else { return }
    await withCheckedContinuation { packageScreenshotDrainWaiters.append($0) }
  }

  public var screenshotsDirectory: URL? {
    applicationOutputPreferences.screenshotsDirectory
  }

  public var isLocalRecording: Bool { recordService != nil }

  @discardableResult
  func installRecordingSubscriptions(
    service: any SessionRecordServicing,
    landscapeHub: ProgramOutputMediaHub,
    portraitHub: ProgramOutputMediaHub,
    recordsLandscape: Bool,
    recordsPortrait: Bool
  ) -> [ProgramOutputMediaHub.Subscription] {
    self.landscapeHub = landscapeHub
    self.portraitHub = portraitHub
    let core = recordMediaCore
    let operationID = outputAttemptID
    if recordsLandscape {
      landscapeSubscription = landscapeHub.subscribe(
        mainVideo: { core.enqueueVideo($0, operationID: operationID) },
        mainAudioMix: core.enqueueMainAudio,
        failureHandler: { [weak self] error in Task { @MainActor in await self?.fail(error) } })
    }
    if recordsPortrait {
      portraitSubscription = portraitHub.subscribe(
        mainVideo: { core.enqueuePortraitVideo($0, operationID: operationID) },
        mainAudioMix: core.enqueuePortraitAudio,
        failureHandler: { [weak self] error in Task { @MainActor in await self?.fail(error) } })
    }
    return [landscapeSubscription, portraitSubscription].compactMap { $0 }
  }

  private func installYouTubeRTMPSSubscriptions(
    _ service: YouTubeRTMPSWorkspaceService,
    landscapeHub: ProgramOutputMediaHub,
    portraitHub: ProgramOutputMediaHub
  ) {
    guard let output = sessionOutputSettings else { return }
    switch output.youtubeSettings?.ingestMode ?? .unspecified {
    case .unspecified, .landscapeRtmps:
      youtubeLandscapeSubscription = landscapeHub.subscribe(
        mainVideo: service.appendLandscapeVideo,
        mainAudioMix: service.appendLandscapeAudioMix,
        failureHandler: service.failMediaDelivery)
    case .portraitRtmps:
      youtubePortraitSubscription = portraitHub.subscribe(
        mainVideo: service.appendPortraitVideo,
        mainAudioMix: service.appendPortraitAudioMix,
        failureHandler: service.failMediaDelivery)
    case .dualRtmps:
      youtubeLandscapeSubscription = landscapeHub.subscribe(
        mainVideo: service.appendLandscapeVideo,
        mainAudioMix: service.appendLandscapeAudioMix,
        failureHandler: service.failMediaDelivery)
      youtubePortraitSubscription = portraitHub.subscribe(
        mainVideo: service.appendPortraitVideo,
        mainAudioMix: service.appendPortraitAudioMix,
        failureHandler: service.failMediaDelivery)
    default:
      break
    }
  }

  private func start(_ session: ActiveDualProgramOutputSession) async throws {
    try await withCheckedThrowingContinuation { continuation in
      session.start(
        programPreferences: landscapePreferences,
        audioDeviceIDsByInputKey: audioDeviceIDsByInputKey(),
        eventHandler: { _ in },
        failureHandler: { [weak self] error in Task { @MainActor in await self?.fail(error) } },
        completionHandler: { continuation.resume(with: $0) })
    }
  }

  private func stop(_ session: ActiveDualProgramOutputSession) async {
    await withCheckedContinuation { continuation in
      session.stop { continuation.resume() }
    }
  }

  private func unsubscribeAndDrain() async {
    if let landscapeHub, let landscapeSubscription {
      _ = await landscapeHub.unsubscribeAndDrain(landscapeSubscription)
    }
    if let portraitHub, let portraitSubscription {
      _ = await portraitHub.unsubscribeAndDrain(portraitSubscription)
    }
    if let landscapeHub, let youtubeLandscapeSubscription {
      _ = await landscapeHub.unsubscribeAndDrain(youtubeLandscapeSubscription)
    }
    if let portraitHub, let youtubePortraitSubscription {
      _ = await portraitHub.unsubscribeAndDrain(youtubePortraitSubscription)
    }
    let subscriptions = inputAudioSubscriptions
    inputAudioSubscriptions = []
    for subscription in subscriptions {
      await withCheckedContinuation { continuation in
        windowRuntime.captureSessionCoordinator.unsubscribeAudio(subscription) {
          continuation.resume()
        }
      }
    }
  }

  private func installInputAudioSubscriptions(
    service: any SessionRecordServicing,
    tracks: [SessionRecordAudioTrack]
  ) async throws {
    let core = recordMediaCore
    for track in tracks {
      guard state == .starting else { return }
      try await withCheckedThrowingContinuation { continuation in
        let subscription = windowRuntime.captureSessionCoordinator.subscribeAudio(
          deviceID: track.deviceID,
          failureHandler: { [weak self] failure in
            Task { @MainActor in await self?.fail(failure) }
          },
          sampleHandler: { sampleBuffer in
            guard let callback = core.beginInputAudioCallback() else { return }
            core.enqueueInputAudio(sampleBuffer, trackID: track.trackID, callback: callback)
          },
          completionHandler: { result in
            continuation.resume(with: result)
          }
        )
        inputAudioSubscriptions.append(subscription)
      }
      guard state == .starting else { return }
    }
  }

  private func finalize(_ service: any SessionRecordServicing) async {
    let result = await withCheckedContinuation { continuation in
      if service.recordingTimelineMilliseconds() == nil {
        service.cancelBeforeFirstVideo { continuation.resume(returning: $0) }
      } else {
        service.stop { continuation.resume(returning: $0) }
      }
    }
    if case .failed(let error) = result {
      recordFailure(error, phase: .recordingFinalization)
    }
  }

  func fail(_ error: Error) async {
    if state == .pausing || state == .stopping {
      recordFailure(error, phase: .output)
      return
    }
    guard state == .starting || state == .recording else { return }
    _ = await beginFinishingOutput(pausing: false, priorFailure: error).value
  }

  // Keep asynchronous publishing completion on the same first-failure path.
  func finishYouTubeOutput(_ finish: () async -> Result<Void, any Error>) async {
    cleanupPhase("youtube", completed: false)
    if case .failure(let error) = await finish() {
      recordFailure(error, phase: .youtubeFinalization)
    }
    cleanupPhase("youtube", completed: true)
  }

  private func recordFailure(_ error: any Error, phase: WorkspaceOutputFailures.Phase) {
    outputFailures.record(error, phase: phase)
    Self.logger.error(
      "output cleanup failure attempt=\(self.outputAttemptID, privacy: .public) phase=\(phase.rawValue, privacy: .public) domain=\((error as NSError).domain, privacy: .private) code=\((error as NSError).code) secondaryCount=\(self.outputFailures.secondary.count)"
    )
  }

  private func cleanupPhase(_ phase: String, completed: Bool) {
    Self.logger.notice(
      "output cleanup attempt=\(self.outputAttemptID, privacy: .public) phase=\(phase, privacy: .public) completed=\(completed)"
    )
  }

  private func clearSessionReferences() {
    windowRuntime.visionArchivePackageURL = nil
    sessionOutputSettings = nil
    windowRuntime.visionArchiveHandler = nil
    windowRuntime.visionArchiveTimedHandler = nil
    windowRuntime.visionArchiveTimelineProvider = nil
    activeSession = nil
    recordService = nil
    recordMediaCore.reset(waitForMediaQueue: false)
    recordingAudioReady = false
    makeReplacementRecording = nil
    preparingRecordingPackages.removeAll()
    preparingRecordingFailures.removeAll()
    youtubeRTMPSService = nil
    landscapeSubscription = nil
    portraitSubscription = nil
    youtubeLandscapeSubscription = nil
    youtubePortraitSubscription = nil
    inputAudioSubscriptions = []
    landscapeHub = nil
    portraitHub = nil
  }

  /// Registers a started recording service independently of native output startup.
  /// A cancelled replacement or a finalized old package cannot fail active
  /// output. Hold a preparation fault until that package becomes current.
  func recordingServiceDidFail(_ error: any Error, packageURL: URL) {
    if recordService?.packageDirectory == packageURL {
      Task { @MainActor in
        guard self.recordService?.packageDirectory == packageURL else { return }
        await self.fail(error)
      }
    } else if preparingRecordingPackages.contains(packageURL) {
      if preparingRecordingFailures[packageURL] == nil {
        preparingRecordingFailures[packageURL] = error as NSError
      }
    }
  }

  func adoptStartedRecordingService(_ service: any SessionRecordServicing) {
    hasCompletedOutputCleanup = false
    recordService = service
    recordingAudioReady = recordMediaCore.hasRequiredAudioFormatDescriptions(for: service)
    preparingRecordingPackages.remove(service.packageDirectory)
    if let failure = preparingRecordingFailures.removeValue(forKey: service.packageDirectory) {
      Task { @MainActor in
        guard self.recordService === service else { return }
        await self.fail(failure)
      }
    }
    if service.hasAcceptedFirstVideo { latestRecordingBundleURL = service.packageDirectory }
    windowRuntime.visionArchiveHandler = { [weak service] internalID, image, output in
      guard let service else { return }
      self.enqueueVisionArchive(
        internalID: internalID, image: image, output: output,
        timelineMilliseconds: service.recordingTimelineMilliseconds(),
        packageDirectory: service.packageDirectory)
    }
    windowRuntime.visionArchiveTimedHandler = { [weak self] id, image, output, timeline, package in
      self?.enqueueVisionArchive(
        internalID: id, image: image, output: output,
        timelineMilliseconds: timeline, packageDirectory: package)
    }
    windowRuntime.visionArchiveTimelineProvider = service.recordingTimelineMilliseconds
    windowRuntime.visionArchivePackageURL = service.packageDirectory
  }

  func enqueueVisionArchive(
    internalID: Int64, image: CIImage, output: String, timelineMilliseconds: UInt64?,
    packageDirectory: URL
  ) {
    visionArchiveQueue.async { [visionArchiveFailure] in
      do {
        try Self.archiveVisionResult(
          internalID: internalID, image: image, output: output,
          timelineMilliseconds: timelineMilliseconds, packageDirectory: packageDirectory)
      } catch {
        visionArchiveFailure.error.withLock { if $0 == nil { $0 = error } }
      }
    }
  }

  private nonisolated static func archiveVisionResult(
    internalID: Int64, image: CIImage, output: String, timelineMilliseconds: UInt64?,
    packageDirectory: URL
  ) throws {
    try VisionResultArchiver().archive(
      internalID: internalID, image: image, output: output,
      timelineMilliseconds: timelineMilliseconds, packageDirectory: packageDirectory)
  }

  private var isFailed: Bool {
    if case .failed = state { return true }
    return false
  }

  private var failureMessage: String? {
    if case .failed(let message) = state { return message }
    return nil
  }

  private var landscapePreferences: ProgramPreferences {
    guard let id = selectedProgramInternalID else { return ProgramPreferences() }
    return preferences(windowRuntime.preferences.landscapeProgramPreferences[id] ?? .init())
  }

  private var selectedProgramInternalID: Int64? {
    let programs = windowRuntime.definition.programs
    guard let selectedID = localStateProvider().selectedProgramInternalID,
      programs.contains(where: { $0.internalID == selectedID })
    else { return programs.first?.internalID }
    return selectedID
  }

  private func portraitPreferences(for programInternalID: Int64) -> ProgramPreferences {
    preferences(windowRuntime.preferences.portraitProgramPreferences[programInternalID] ?? .init())
  }

  private func preferences(_ preference: Ldtx_Workspace_V4_ProgramPreferences) -> ProgramPreferences
  {
    let gain =
      (preference.audioMasterVolumeDecibels?.double ?? 0)
    var preferences = ProgramPreferences(
      masterVolume: ProgramPreferences.linearAudioChannelGain(fromDecibels: gain))
    let gains = windowRuntime.preferences.audioChannelGainsDecibels
    let muted = preference.audioChannelMuted
    for inputDeviceInternalID in Set(gains.keys).union(muted.keys) {
      let key = "v4-\(inputDeviceInternalID)"
      preferences.audioChannelGainsByName[key] =
        ProgramPreferences.linearAudioChannelGain(
          fromDecibels: (gains[inputDeviceInternalID]?.double ?? 0))
      preferences.audioMutedByInputDeviceName[key] = muted[inputDeviceInternalID] ?? false
    }
    return preferences
  }

  private func audioDeviceIDsByInputKey() -> [String: String] {
    Dictionary(
      uniqueKeysWithValues: windowRuntime.definition.audioDevices
        .compactMap {
          let input = $0
          guard let inputID = input.internalID,
            case .coreAudioDevice(let physicalID)? = physicalDeviceIDsProvider()[inputID]
          else { return nil }
          return ("v4-\(inputID)", physicalID)
        })
  }

  private var inputAudioTracks: [SessionRecordAudioTrack] {
    let names: [String: String] = Dictionary(
      uniqueKeysWithValues:
        windowRuntime.definition.audioDevices.compactMap { input in
          guard let id = input.internalID, let name = input.displayName else { return nil }
          return ("v4-\(id)", name)
        })
    return SessionRecordAudioTrack.make(
      deviceIDsByInputKey: audioDeviceIDsByInputKey(), deviceNamesByInputKey: names)
  }

  private func makeYouTubeRTMPSService(
    for output: Ldtx_Workspace_V4_WorkspaceOutputSettingsV4
  ) throws -> YouTubeRTMPSWorkspaceService {
    let configurations = try streamKeyConfigurationsProvider()
    let destinations = try WorkspaceV4YouTubeRTMPSDestinationResolver.resolve(
      output: output, configurations: configurations,
      landscapeStreamID: localStateProvider().landscapeYouTubeLiveStreamID,
      portraitStreamID: localStateProvider().portraitYouTubeLiveStreamID)
    return YouTubeRTMPSWorkspaceService(
      destinations: destinations,
      failureHandler: { [weak self] error in
        Task { @MainActor in await self?.fail(error) }
      })
  }

  private func outputDirectory() -> URL {
    if let path = localStateProvider().recordingFolderPath, !path.isEmpty {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    if let path = applicationOutputPreferences.defaultOutputFolderPath,
      !path.isEmpty
    {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return DefaultLocalOutputService(fileManager: .default).defaultBaseDirectory
  }

  private var applicationOutputPreferences: ApplicationOutputPreferences {
    ApplicationSettingsStore().loadApplicationOutputPreferences()
  }

  private func requestRequiredCaptureAccess(
    configurations: [ProgramRuntimeConfiguration]
  ) async throws {
    let requiresVideoAccess = configurations.contains { configuration in
      configuration.composite.steps.contains { step in
        guard case .inputCameraDevice(let input) = step.component,
          let inputDeviceID = input.inputDeviceID
        else { return false }
        return configuration.cameraIDsByInputKey[inputDeviceID] != nil
      }
    }
    let audioInputIDs = Set(
      configurations.flatMap { configuration in
        configuration.audioChannels.compactMap { channel -> Int64? in
          guard case .inputAudioDevice(let input) = channel.component,
            let inputDeviceID = input.inputDeviceID,
            inputDeviceID.hasPrefix("v4-"),
            let id = Int64(inputDeviceID.dropFirst(3))
          else { return nil }
          return id
        }
      })
    if requiresVideoAccess, await requestVideoAccess() == false {
      throw CameraCaptureServiceError.cameraAccessDenied
    }
    if audioInputIDs.contains(where: {
      if case .coreAudioDevice? = physicalDeviceIDsProvider()[$0] {
        true
      } else {
        false
      }
    }),
      await AVAudioApplication.requestRecordPermission() == false
    {
      throw WorkspaceV4RecordingSessionError.microphoneAccessDenied
    }
  }

  private func requestVideoAccess() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      true
    case .notDetermined:
      await withCheckedContinuation { continuation in
        AVCaptureDevice.requestAccess(for: .video) { continuation.resume(returning: $0) }
      }
    case .denied, .restricted:
      false
    @unknown default:
      false
    }
  }
}
