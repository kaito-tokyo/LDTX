// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFAudio
import AVFoundation
import CoreImage
import Foundation
import ImageIO
import LDTXAppletSupport
import LDTXBackgroundSegmentation
import LDTXCapture
import LDTXProgram
import LDTXProgramRuntime
import LDTXProtos
import LDTXRecordBundleFormat
import LDTXRecording
import LDTXTaskQueue
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletStore
import LDTXYouTubeRTMPS
import Observation
import Synchronization
import UniformTypeIdentifiers

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
  private var recordService: SessionRecordService?
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
  private var terminalFailureMessage: String?
  @ObservationIgnored private var currentStoppingFailure: NSError?
  private let screenCaptureService: ScreenCaptureService
  @ObservationIgnored private var pendingScreenshotCount = 0
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
    streamKeyConfigurations: @escaping () throws -> [YouTubeRTMPSStreamKeyConfiguration] = { [] }
  ) {
    self.screenCaptureService = screenCaptureService
    self.windowRuntime = windowRuntime
    self.physicalDeviceIDsProvider = physicalDeviceIDs
    self.localStateProvider = localState
    self.visionArchiveQueue = visionArchiveQueue
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
    let recordsLandscape = output.recordingEnabled && output.recordingSettings.recordsLandscape
    let recordsPortrait = output.recordingEnabled && output.recordingSettings.recordsPortrait
    guard recordsLandscape || recordsPortrait || output.youtubeEnabled else {
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
      || (output.youtubeEnabled && output.youtubeSettings.ingestMode.usesLandscapeRTMPS)
    let runsPortrait =
      recordsPortrait
      || (output.youtubeEnabled && output.youtubeSettings.ingestMode.usesPortraitRTMPS)
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
      state = .failed(error.localizedDescription)
      return .failure(error as NSError)
    }

    let youtubeService: YouTubeRTMPSWorkspaceService?
    do {
      youtubeService = output.youtubeEnabled ? try makeYouTubeRTMPSService(for: output) : nil
    } catch {
      sleepInhibitor.stop()
      state = .failed(error.localizedDescription)
      return .failure(error as NSError)
    }
    let service: SessionRecordService?
    do {
      if recordsLandscape || recordsPortrait {
        let recordService = try SessionRecordService(
          baseDirectory: baseDirectory,
          recordID: SessionRecordService.makeRecordID(),
          writerConfiguration: ProgramOutputEncodingConfiguration.make(
            configuration: landscapeConfiguration),
          portraitWriterConfiguration: ProgramOutputEncodingConfiguration.make(
            configuration: portraitConfiguration),
          audioTracks: inputAudioTracks,
          recordsLandscape: recordsLandscape,
          recordsPortrait: recordsPortrait,
          customFields: output.recordingSettings.customFields,
          firstVideoAccepted: { [weak self] url in
            self?.latestRecordingBundleURL = url
          },
          failureHandler: { [weak self] error in
            Task { @MainActor in await self?.fail(error) }
          })
        try recordService.start()
        adoptStartedRecordingService(recordService)
        service = recordService
      } else {
        service = nil
      }
    } catch {
      sleepInhibitor.stop()
      state = .failed(error.localizedDescription)
      return .failure(error as NSError)
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
      return .failure(error as NSError)
    }
  }

  private func interruptedStartResult() async -> Result<Void, NSError> {
    _ = await stoppingTask?.value
    let message = failureMessage ?? "Output startup did not complete."
    return .failure(
      NSError(
        domain: "WorkspaceOutput", code: 2,
        userInfo: [NSLocalizedDescriptionKey: message]))
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
    return await beginFinishingOutput(pausing: pausing, priorFailure: failureMessage).value
  }

  private func beginFinishingOutput(pausing: Bool, priorFailure: String?) -> Task<
    Result<Void, NSError>, Never
  > {
    // Lock out another request before the task reaches its first suspension.
    terminalFailureMessage = priorFailure
    currentStoppingFailure = nil
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
    windowRuntime.visionArchivePackageURL = nil
    windowRuntime.visionArchiveHandler = nil
    windowRuntime.visionArchiveTimelineProvider = nil
    if let activeSession { await stop(activeSession) }
    await unsubscribeAndDrain()
    await withCheckedContinuation { continuation in
      visionArchiveQueue.async { continuation.resume() }
    }
    if let error = visionArchiveFailure.error.withLock({ error in
      defer { error = nil }
      return error
    }) {
      terminalFailureMessage = error.localizedDescription
      currentStoppingFailure = error as NSError
    }
    await screenCaptureService.drain()
    if let recordService {
      await finalize(recordService)
    }
    if let youtubeRTMPSService {
      if case .failure(let error) = await youtubeRTMPSService.finish() {
        terminalFailureMessage = error.localizedDescription
        currentStoppingFailure = error as NSError
      }
    }
    clearSessionReferences()
    sleepInhibitor.stop()
    state = terminalFailureMessage.map(State.failed) ?? (pausing ? .paused : .idle)
    terminalFailureMessage = nil
    let result: Result<Void, NSError> = currentStoppingFailure.map { .failure($0) } ?? .success(())
    currentStoppingFailure = nil
    return result
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
      _ = beginFinishingOutput(pausing: false, priorFailure: error.localizedDescription)
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
      guard case .vfxSource(let input)? = wrapper.videoComponent,
        case .avCaptureDevice(let cameraID)? = physicalDeviceIDsProvider()[input.internalID],
        let frame = windowRuntime.captureSessionCoordinator.latestFrame(forCameraID: cameraID)
      else { continue }
      sources.append(ScreenCaptureSource(name: input.displayName, pixelBuffer: frame.pixelBuffer))
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
    // Snapshot and admission share MainActor with pause/stop. Finalization drains
    // accepted copies; later requests see the transition state and save globally.
    if state == .recording, let recordService,
      recordService.hasAcceptedFirstVideo,
      recordService.recordingTimelineMilliseconds() != nil
    {
      directories.append(recordService.packageDirectory.appendingPathComponent("Screenshots"))
    }
    return try await screenCaptureService.enqueueCapture(
      sources: snapshots, capturedAt: capturedAt, outputDirectories: directories
    ).screenshots.filter {
      $0.url.deletingLastPathComponent().standardizedFileURL == globalDirectory.standardizedFileURL
    }
  }

  public var screenshotsDirectory: URL? {
    applicationOutputPreferences.screenshotsDirectory
  }

  public var isLocalRecording: Bool { recordService != nil }

  private func installRecordingSubscriptions(
    service: SessionRecordService,
    landscapeHub: ProgramOutputMediaHub,
    portraitHub: ProgramOutputMediaHub,
    recordsLandscape: Bool,
    recordsPortrait: Bool
  ) {
    if recordsLandscape {
      landscapeSubscription = landscapeHub.subscribe(
        mainVideo: service.appendMainVideo,
        mainAudioMix: service.appendMainAudioMix,
        failureHandler: { [weak self] error in Task { @MainActor in await self?.fail(error) } })
    }
    if recordsPortrait {
      portraitSubscription = portraitHub.subscribe(
        mainVideo: service.appendPortraitVideo,
        mainAudioMix: service.appendPortraitAudioMix,
        failureHandler: { [weak self] error in Task { @MainActor in await self?.fail(error) } })
    }
  }

  private func installYouTubeRTMPSSubscriptions(
    _ service: YouTubeRTMPSWorkspaceService,
    landscapeHub: ProgramOutputMediaHub,
    portraitHub: ProgramOutputMediaHub
  ) {
    guard let output = sessionOutputSettings else { return }
    switch output.youtubeSettings.ingestMode {
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
    service: SessionRecordService,
    tracks: [SessionRecordAudioTrack]
  ) async throws {
    for track in tracks {
      guard state == .starting else { return }
      try await withCheckedThrowingContinuation { continuation in
        let subscription = windowRuntime.captureSessionCoordinator.subscribeAudio(
          deviceID: track.deviceID,
          failureHandler: { [weak self] failure in
            Task { @MainActor in await self?.fail(failure) }
          },
          sampleHandler: { sampleBuffer in
            service.appendInputAudio(sampleBuffer, trackID: track.trackID)
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

  private func finalize(_ service: SessionRecordService) async {
    let result = await withCheckedContinuation { continuation in
      if service.recordingTimelineMilliseconds() == nil {
        service.cancelBeforeFirstVideo { continuation.resume(returning: $0) }
      } else {
        service.stop { continuation.resume(returning: $0) }
      }
    }
    if case .failed(let error) = result {
      terminalFailureMessage = error.localizedDescription
      currentStoppingFailure = error as NSError
    }
  }

  func fail(_ error: Error) async {
    if state == .pausing || state == .stopping {
      terminalFailureMessage = error.localizedDescription
      currentStoppingFailure = error as NSError
      return
    }
    guard state == .starting || state == .recording else { return }
    state = .failed(error.localizedDescription)
    await stop()
  }

  private func clearSessionReferences() {
    windowRuntime.visionArchivePackageURL = nil
    sessionOutputSettings = nil
    windowRuntime.visionArchiveHandler = nil
    windowRuntime.visionArchiveTimelineProvider = nil
    activeSession = nil
    recordService = nil
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
  func adoptStartedRecordingService(_ service: SessionRecordService) {
    recordService = service
    windowRuntime.visionArchiveHandler = { [weak service] internalID, image, output in
      guard let service else { return }
      self.enqueueVisionArchive(
        internalID: internalID, image: image, output: output,
        timelineMilliseconds: service.recordingTimelineMilliseconds(),
        packageDirectory: service.packageDirectory)
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
    let directory = packageDirectory.appendingPathComponent("Visions", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stem = "vision-\(internalID)-\(UInt64(Date().timeIntervalSince1970 * 1_000))"
    let imageURL = directory.appendingPathComponent("\(stem).jpg")
    let metadataURL = directory.appendingPathComponent("\(stem).json")
    let context = CIContext(options: [.cacheIntermediates: false])
    guard let cgImage = context.createCGImage(image, from: image.extent),
      let destination = CGImageDestinationCreateWithURL(
        imageURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: imageURL])
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: imageURL])
    }
    var metadata: [String: String] = ["visionID": String(internalID), "output": output]
    if let timelineMilliseconds {
      metadata["recordingTimelineMilliseconds"] = String(timelineMilliseconds)
    }
    let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
    try data.write(to: metadataURL, options: .atomic)
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
      (preference.hasAudioMasterVolumeDecibels ? preference.audioMasterVolumeDecibels.double : 0)
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
          guard
            case .coreAudioDevice(let physicalID)? = physicalDeviceIDsProvider()[input.internalID]
          else { return nil }
          return ("v4-\(input.internalID)", physicalID)
        })
  }

  private var inputAudioTracks: [SessionRecordAudioTrack] {
    let names: [String: String] = Dictionary(
      uniqueKeysWithValues:
        windowRuntime.definition.audioDevices.compactMap { input in
          let device = input
          return ("v4-\(device.internalID)", device.displayName)
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
