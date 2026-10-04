// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFAudio
import AVFoundation
import CoreImage
import Foundation
import ImageIO
import LDTXAppletSupport
import LDTXCapture
import LDTXProgram
import LDTXProgramRuntime
import LDTXRecording
import LDTXWorkspaceAppletInterface
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletStore
import LDTXYouTubeRTMPS
import Observation
import UniformTypeIdentifiers

private enum WorkspaceV4RecordingSessionError: Error, LocalizedError {
  case microphoneAccessDenied

  var errorDescription: String? {
    "Microphone access was not granted."
  }
}

/// Owns recording and streaming for one Version 4 Workspace Output.
@MainActor
@Observable
public final class WorkspaceV4RecordingSession {
  public typealias State = WorkspaceRecordingState

  private let windowRuntime: WorkspaceWindowRuntime
  private let physicalDeviceIDsProvider: () -> [UInt64: WorkspacePhysicalDeviceID]
  private let localStateProvider: () -> WorkspaceLocalState
  private let streamKeyConfigurationsProvider: () throws -> [YouTubeRTMPSStreamKeyConfiguration]
  private var activeSession: ActiveDualProgramOutputSession?
  private var recordService: SessionRecordService?
  private var youtubeRTMPSService: YouTubeRTMPSWorkspaceService?
  private let visionArchiveQueue = DispatchQueue(label: "tokyo.kaito.ldtx.v4-vision-archive")
  private var landscapeSubscription: ProgramOutputMediaHub.Subscription?
  private var portraitSubscription: ProgramOutputMediaHub.Subscription?
  private var landscapeHub: ProgramOutputMediaHub?
  private var portraitHub: ProgramOutputMediaHub?
  private var youtubeLandscapeSubscription: ProgramOutputMediaHub.Subscription?
  private var youtubePortraitSubscription: ProgramOutputMediaHub.Subscription?
  private var inputAudioSubscriptions: [WorkspaceCaptureSessionCoordinator.AudioSubscription] = []
  @ObservationIgnored private var stoppingTask: Task<Void, Never>?
  private var terminalFailureMessage: String?
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
    physicalDeviceIDs: @escaping () -> [UInt64: WorkspacePhysicalDeviceID] = { [:] },
    localState: @escaping () -> WorkspaceLocalState = { .init() },
    streamKeyConfigurations: @escaping () throws -> [YouTubeRTMPSStreamKeyConfiguration] = { [] }
  ) {
    self.windowRuntime = windowRuntime
    self.physicalDeviceIDsProvider = physicalDeviceIDs
    self.localStateProvider = localState
    self.streamKeyConfigurationsProvider = streamKeyConfigurations
  }

  public var isRecording: Bool { state.isOutputActive }

  public func start() async {
    guard state.canStart else { return }
    if isFailed {
      clearSessionReferences()
      state = .idle
    }
    guard let selectedProgramInternalID = selectedProgramInternalID else {
      state = .failed("Select a Program before starting recording.")
      return
    }
    let output = windowRuntime.definition.outputConfiguration
    guard output.recordsLandscape || output.recordsPortrait || output.streamsToYoutube else {
      state = .failed("Enable recording or YouTube streaming in Output settings.")
      return
    }
    guard let landscapeRuntime = windowRuntime.runtime(isPortrait: false),
      let portraitRuntime = windowRuntime.runtime(isPortrait: true)
    else {
      state = .failed("The selected Program runtime is unavailable.")
      return
    }
    guard let landscapeConfiguration = landscapeRuntime.programState.read({ $0 }),
      let portraitConfiguration = portraitRuntime.programState.read({ $0 })
    else {
      state = .failed("The selected Program has not been rendered yet.")
      return
    }

    state = .starting
    sleepInhibitor.start()
    let baseDirectory = outputDirectory(for: output)
    let runsLandscape =
      output.recordsLandscape
      || (output.streamsToYoutube && output.resolvedYouTubeIngestMode != .portraitRtmps)
    let runsPortrait =
      output.recordsPortrait
      || (output.streamsToYoutube && output.resolvedYouTubeIngestMode != .landscapeRtmps)
    do {
      if output.recordsLandscape || output.recordsPortrait {
        try DefaultLocalOutputService(fileManager: .default).validateWritableBaseDirectory(
          baseDirectory)
      }
      try await requestRequiredCaptureAccess(
        configurations: [
          runsLandscape ? landscapeConfiguration : nil,
          runsPortrait ? portraitConfiguration : nil,
        ].compactMap { $0 }
      )
      guard state == .starting else { return }
    } catch {
      sleepInhibitor.stop()
      state = .failed(error.localizedDescription)
      return
    }

    let youtubeService: YouTubeRTMPSWorkspaceService?
    do {
      youtubeService = output.streamsToYoutube ? try makeYouTubeRTMPSService(for: output) : nil
    } catch {
      sleepInhibitor.stop()
      state = .failed(error.localizedDescription)
      return
    }
    let service: SessionRecordService?
    do {
      if output.recordsLandscape || output.recordsPortrait {
        let recordService = try SessionRecordService(
          baseDirectory: baseDirectory,
          recordID: SessionRecordService.makeRecordID(),
          writerConfiguration: ProgramOutputEncodingConfiguration.make(
            configuration: landscapeConfiguration),
          portraitWriterConfiguration: ProgramOutputEncodingConfiguration.make(
            configuration: portraitConfiguration),
          audioTracks: inputAudioTracks,
          recordsLandscape: output.recordsLandscape,
          recordsPortrait: output.recordsPortrait,
          customFields: output.recordingCustomFields,
          diagnosticsContext: RecordingDiagnosticsContext(),
          failureHandler: { [weak self] error in
            Task { @MainActor in await self?.fail(error) }
          })
        try recordService.start()
        windowRuntime.visionArchiveHandler = { [weak recordService] internalID, image, output in
          guard let recordService else { return }
          let timelineMilliseconds = recordService.recordingTimelineMilliseconds()
          let packageDirectory = recordService.packageDirectory
          self.visionArchiveQueue.async {
            Self.archiveVisionResult(
              internalID: internalID, image: image, output: output,
              timelineMilliseconds: timelineMilliseconds,
              packageDirectory: packageDirectory)
          }
        }
        windowRuntime.visionArchiveTimelineProvider = recordService.recordingTimelineMilliseconds
        service = recordService
      } else {
        service = nil
      }
    } catch {
      sleepInhibitor.stop()
      state = .failed(error.localizedDescription)
      return
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
        recordsLandscape: output.recordsLandscape, recordsPortrait: output.recordsPortrait)
    }
    if let youtubeService {
      installYouTubeRTMPSSubscriptions(
        youtubeService, landscapeHub: landscapeHub, portraitHub: portraitHub)
      youtubeRTMPSService = youtubeService
    }
    activeSession = outputSession
    recordService = service
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
      guard state == .starting else { return }
      state = .recording
    } catch {
      await fail(error)
    }
  }

  public func pause() async {
    guard state == .recording else { return }
    await finishOutput(pausing: true)
  }

  public func stop() async {
    if state == .paused {
      state = .idle
      return
    }
    await finishOutput(pausing: false)
    // A shutdown request that joined Pause must also leave the session idle.
    if state == .paused { state = .idle }
  }

  private func finishOutput(pausing: Bool) async {
    if let stoppingTask {
      await stoppingTask.value
      return
    }
    guard state == .starting || state == .recording || isFailed else { return }
    await beginFinishingOutput(pausing: pausing, priorFailure: failureMessage).value
  }

  private func beginFinishingOutput(pausing: Bool, priorFailure: String?) -> Task<Void, Never> {
    // Lock out another request before the task reaches its first suspension.
    terminalFailureMessage = priorFailure
    state = pausing ? .pausing : .stopping
    let task = Task { @MainActor in
      await finishStopping(pausing: pausing)
      stoppingTask = nil
    }
    stoppingTask = task
    return task
  }

  private func finishStopping(pausing: Bool) async {
    if let activeSession { await stop(activeSession) }
    await unsubscribeAndDrain()
    if let recordService {
      await finalize(recordService)
    }
    if let youtubeRTMPSService {
      if case .failure(let error) = await youtubeRTMPSService.finish() {
        terminalFailureMessage = error.localizedDescription
      }
    }
    clearSessionReferences()
    sleepInhibitor.stop()
    state = terminalFailureMessage.map(State.failed) ?? (pausing ? .paused : .idle)
    terminalFailureMessage = nil
  }

  public func reconfigureProgramOutput() throws {
    guard state == .recording, let activeSession, let programID = selectedProgramInternalID else {
      return
    }
    guard
      activeSession.reconfigureAudio(
        landscapePreferences: preferences(for: programID, isPortrait: false),
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

  public func updateMixPreferences() {
    guard let activeSession, let programID = selectedProgramInternalID else {
      return
    }
    activeSession.updateProgramPreferences(preferences(for: programID, isPortrait: false))
    activeSession.updatePortraitProgramPreferences(portraitPreferences(for: programID))
  }

  public func captureScreenshots() throws -> [URL] {
    guard let recordService else { throw ScreenCaptureError.frameUnavailable }
    var sources: [ScreenCaptureSource] = []
    if let frame = windowRuntime.runtime(isPortrait: false)?.latestFrame() {
      sources.append(ScreenCaptureSource(name: "Landscape", pixelBuffer: frame.pixelBuffer))
    }
    if let frame = windowRuntime.runtime(isPortrait: true)?.latestFrame() {
      sources.append(ScreenCaptureSource(name: "Portrait", pixelBuffer: frame.pixelBuffer))
    }
    for wrapper in windowRuntime.definition.inputDevices {
      guard case .videoDevice(let input)? = wrapper.definition,
        case .avCaptureDevice(let cameraID)? = physicalDeviceIDsProvider()[input.internalID],
        let frame = windowRuntime.captureSessionCoordinator.latestFrame(forCameraID: cameraID)
      else { continue }
      sources.append(ScreenCaptureSource(name: input.displayName, pixelBuffer: frame.pixelBuffer))
    }
    return try ScreenCaptureService().captureSet(
      sources: sources, capturedAt: Date(),
      recordingPackageDirectory: recordService.packageDirectory
    ).outputURLs
  }

  public var screenshotsDirectory: URL? {
    recordService?.packageDirectory.appendingPathComponent("Screenshots", isDirectory: true)
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
    let output = windowRuntime.definition.outputConfiguration
    switch output.resolvedYouTubeIngestMode {
    case .landscapeRtmps:
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
    }
  }

  func fail(_ error: Error) async {
    if state == .pausing || state == .stopping {
      terminalFailureMessage = error.localizedDescription
      return
    }
    guard state == .starting || state == .recording else { return }
    state = .failed(error.localizedDescription)
    await stop()
  }

  private func clearSessionReferences() {
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

  private nonisolated static func archiveVisionResult(
    internalID: UInt64, image: CIImage, output: String, timelineMilliseconds: UInt64?,
    packageDirectory: URL
  ) {
    let directory = packageDirectory.appendingPathComponent("Visions", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stem = "vision-\(internalID)-\(UInt64(Date().timeIntervalSince1970 * 1_000))"
    let imageURL = directory.appendingPathComponent("\(stem).jpg")
    let metadataURL = directory.appendingPathComponent("\(stem).json")
    let context = CIContext(options: [.cacheIntermediates: false])
    if let cgImage = context.createCGImage(image, from: image.extent),
      let destination = CGImageDestinationCreateWithURL(
        imageURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    {
      CGImageDestinationAddImage(destination, cgImage, nil)
      _ = CGImageDestinationFinalize(destination)
    }
    var metadata: [String: String] = ["visionID": String(internalID), "output": output]
    if let timelineMilliseconds {
      metadata["recordingTimelineMilliseconds"] = String(timelineMilliseconds)
    }
    if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) {
      try? data.write(to: metadataURL, options: .atomic)
    }
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
    return preferences(for: id, isPortrait: false)
  }

  private var selectedProgramInternalID: UInt64? {
    let programs = windowRuntime.definition.programs
    guard let selectedID = localStateProvider().selectedProgramInternalID,
      programs.contains(where: { $0.internalID == selectedID })
    else { return programs.first?.internalID }
    return selectedID
  }

  private func portraitPreferences(for programInternalID: UInt64) -> ProgramPreferences {
    preferences(
      for: programInternalID,
      isPortrait: true)
  }

  private func preferences(for programInternalID: UInt64, isPortrait: Bool)
    -> ProgramPreferences
  {
    let preference =
      (isPortrait
      ? windowRuntime.preferences.portraitProgramPreferences
      : windowRuntime.preferences.landscapeProgramPreferences)[programInternalID] ?? .init()
    let gain = Double(preference.audioMasterVolumeDecibelTenths) / 10
    var preferences = ProgramPreferences(
      masterVolume: ProgramPreferences.linearAudioChannelGain(fromDecibels: gain))
    let gains = preference.audioChannelGainsDecibelTenths
    let muted = preference.audioChannelMuted
    for inputDeviceInternalID in Set(gains.keys).union(muted.keys) {
      let key = "v4-\(inputDeviceInternalID)"
      preferences.audioChannelGainsByName[key] =
        ProgramPreferences.linearAudioChannelGain(
          fromDecibels: Double(gains[inputDeviceInternalID] ?? 0) / 10)
      preferences.audioMutedByInputDeviceName[key] = muted[inputDeviceInternalID] ?? false
    }
    return preferences
  }

  private func audioDeviceIDsByInputKey() -> [String: String] {
    Dictionary(
      uniqueKeysWithValues: windowRuntime.definition.inputDevices
        .compactMap {
          guard case .audioDevice(let input)? = $0.definition,
            case .coreAudioDevice(let physicalID)? = physicalDeviceIDsProvider()[input.internalID]
          else { return nil }
          return ("v4-\(input.internalID)", physicalID)
        })
  }

  private var inputAudioTracks: [SessionRecordAudioTrack] {
    let names: [String: String] = Dictionary(
      uniqueKeysWithValues:
        windowRuntime.definition.inputDevices.compactMap { input in
          guard case .audioDevice(let device)? = input.definition else { return nil }
          return ("v4-\(device.internalID)", device.displayName)
        })
    return SessionRecordAudioTrack.make(
      deviceIDsByInputKey: audioDeviceIDsByInputKey(), deviceNamesByInputKey: names)
  }

  private func makeYouTubeRTMPSService(
    for output: Ldtx_Workspace_V4_OutputConfiguration
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

  private func outputDirectory(for output: Ldtx_Workspace_V4_OutputConfiguration) -> URL {
    if output.hasOutputFolderPath, !output.outputFolderPath.isEmpty {
      return URL(fileURLWithPath: output.outputFolderPath, isDirectory: true)
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
        configuration.audioChannels.compactMap { channel -> UInt64? in
          guard case .inputAudioDevice(let input) = channel.component,
            let inputDeviceID = input.inputDeviceID,
            inputDeviceID.hasPrefix("v4-"),
            let id = UInt64(inputDeviceID.dropFirst(3))
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
