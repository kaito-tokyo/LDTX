// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation
import LDTXCapture
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
import LDTXYouTubeRTMPS
import Observation

/// Owns local recording for a Version 4 Workspace without consulting a V3
/// Workspace model or `WorkspaceContainer`.
@MainActor
@Observable
final class WorkspaceV4RecordingSession {
  enum State: Equatable {
    case idle
    case starting
    case recording
    case stopping
    case failed(String)
  }

  private let workspaceSession: WorkspaceV4RuntimeSession
  private var activeSession: ActiveDualProgramOutputSession?
  private var recordService: SessionRecordService?
  private var youtubeRTMPSService: YouTubeRTMPSWorkspaceService?
  private var landscapeSubscription: ProgramOutputMediaHub.Subscription?
  private var portraitSubscription: ProgramOutputMediaHub.Subscription?
  private var landscapeHub: ProgramOutputMediaHub?
  private var portraitHub: ProgramOutputMediaHub?
  private var youtubeLandscapeSubscription: ProgramOutputMediaHub.Subscription?
  private var youtubePortraitSubscription: ProgramOutputMediaHub.Subscription?
  private var inputAudioSubscriptions: [WorkspaceCaptureSessionCoordinator.AudioSubscription] = []
  var state: State = .idle

  init(workspaceSession: WorkspaceV4RuntimeSession) {
    self.workspaceSession = workspaceSession
  }

  var isRecording: Bool { state == .recording || state == .starting || state == .stopping }

  func start() async {
    guard state == .idle || isFailed else { return }
    if isFailed {
      clearSessionReferences()
      state = .idle
    }
    guard let selectedProgramInternalID = workspaceSession.selectedProgramInternalID else {
      state = .failed("Select a Program before starting recording.")
      return
    }
    let output = workspaceSession.store.workspace.definition.definition.outputConfiguration
    guard output.recordsLandscape || output.recordsPortrait || output.streamsToYoutube else {
      state = .failed("Enable recording or YouTube streaming in Output settings.")
      return
    }
    guard let landscapeRuntime = workspaceSession.runtime(for: .landscape),
      let portraitRuntime = workspaceSession.runtime(for: .portrait)
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

    let baseDirectory = outputDirectory(for: output)
    do {
      if output.recordsLandscape || output.recordsPortrait {
        try DefaultLocalOutputService(fileManager: .default).validateWritableBaseDirectory(baseDirectory)
      }
      try await requestRequiredCaptureAccess(
        configurations: [landscapeConfiguration, portraitConfiguration]
      )
    } catch {
      state = .failed(error.localizedDescription)
      return
    }

    state = .starting
    let youtubeService: YouTubeRTMPSWorkspaceService?
    do {
      youtubeService = output.streamsToYoutube ? try makeYouTubeRTMPSService(for: output) : nil
    } catch {
      state = .failed(error.localizedDescription)
      return
    }
    let service: SessionRecordService?
    do {
      if output.recordsLandscape || output.recordsPortrait {
        let recordService = try SessionRecordService(
          baseDirectory: baseDirectory,
          recordID: SessionRecordService.makeRecordID(),
          writerConfiguration: ProgramOutputEncodingConfiguration.make(configuration: landscapeConfiguration),
          portraitWriterConfiguration: ProgramOutputEncodingConfiguration.make(
            configuration: portraitConfiguration),
          audioTracks: inputAudioTracks,
          recordsLandscape: output.recordsLandscape,
          recordsPortrait: output.recordsPortrait,
          customFields: output.recordingCustomFields,
          failureHandler: { [weak self] error in
            Task { @MainActor in await self?.fail(error) }
          })
        try recordService.start()
        service = recordService
      } else {
        service = nil
      }
    } catch {
      state = .failed(error.localizedDescription)
      return
    }

    let landscapeHub = ProgramOutputMediaHub()
    let portraitHub = ProgramOutputMediaHub()
    let outputSession = ActiveDualProgramOutputSession(
      landscapeRuntime: landscapeRuntime,
      portraitRuntime: portraitRuntime,
      captureSessionCoordinator: workspaceSession.captureSessionCoordinator,
      landscapeMediaHub: landscapeHub,
      portraitMediaHub: portraitHub,
      portraitPreferences: portraitPreferences(for: selectedProgramInternalID),
      portraitAudioDeviceIDsByInputKey: audioDeviceIDsByInputKey())
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
      try await start(outputSession)
      if let service {
        try await installInputAudioSubscriptions(service: service, tracks: inputAudioTracks)
      }
      guard state == .starting else { return }
      state = .recording
    } catch {
      await fail(error)
    }
  }

  func stop() async {
    guard state == .starting || state == .recording || isFailed else { return }
    let failureMessage = failureMessage
    state = .stopping
    if let activeSession { await stop(activeSession) }
    await unsubscribeAndDrain()
    if let recordService {
      await finalize(recordService)
    }
    if let youtubeRTMPSService {
      _ = await youtubeRTMPSService.finish()
    }
    clearSessionReferences()
    state = failureMessage.map(State.failed) ?? .idle
  }

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
    let output = workspaceSession.store.workspace.definition.definition.outputConfiguration
    switch output.youtubeIngestMode {
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
        workspaceSession.captureSessionCoordinator.unsubscribeAudio(subscription) {
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
      try await withCheckedThrowingContinuation { continuation in
        let subscription = workspaceSession.captureSessionCoordinator.subscribeAudio(
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
    }
  }

  private func finalize(_ service: SessionRecordService) async {
    await withCheckedContinuation { continuation in
      service.stop { _ in continuation.resume() }
    }
  }

  private func fail(_ error: Error) async {
    guard state == .starting || state == .recording else { return }
    state = .failed(error.localizedDescription)
    await stop()
  }

  private func clearSessionReferences() {
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

  private var isFailed: Bool {
    if case .failed = state { return true }
    return false
  }

  private var failureMessage: String? {
    if case .failed(let message) = state { return message }
    return nil
  }

  private var landscapePreferences: ProgramPreferences {
    guard let id = workspaceSession.selectedProgramInternalID else { return ProgramPreferences() }
    return preferences(for: id, role: .landscape)
  }

  private func portraitPreferences(for programInternalID: UInt64) -> ProgramPreferences {
    preferences(
      for: programInternalID,
      role: workspaceSession.synchronizesLandscapeMixToPortrait(for: programInternalID)
        ? .landscape : .portrait)
  }

  private func preferences(for programInternalID: UInt64, role: ProgramCanvasRole) -> ProgramPreferences {
    let preference = workspaceSession.store.workspace.preferences.preferences.programPreferences[
      programInternalID] ?? .init()
    let gain = role == .landscape ? preference.landscapeMasterVolume : preference.portraitMasterVolume
    return ProgramPreferences(masterVolume: ProgramPreferences.linearAudioChannelGain(fromDecibels: gain))
  }

  private func audioDeviceIDsByInputKey() -> [String: String] {
    Dictionary(uniqueKeysWithValues: workspaceSession.store.workspace.definition.definition.inputDevices.compactMap {
      guard case .audioDevice(let input)? = $0.definition,
        let physicalID = workspaceSession.physicalAudioDeviceID(for: input.internalID)
      else { return nil }
      return ("v4-\(input.internalID)", physicalID)
    })
  }

  private var inputAudioTracks: [SessionRecordAudioTrack] {
    let names: [String: String] = Dictionary(uniqueKeysWithValues:
      workspaceSession.store.workspace.definition.definition.inputDevices.compactMap { input in
        guard case .audioDevice(let device)? = input.definition else { return nil }
        return ("v4-\(device.internalID)", device.displayName)
      })
    return SessionRecordAudioTrack.make(
      deviceIDsByInputKey: audioDeviceIDsByInputKey(), deviceNamesByInputKey: names)
  }

  private func makeYouTubeRTMPSService(
    for output: Ldtx_Workspace_V4_OutputConfiguration
  ) throws -> YouTubeRTMPSWorkspaceService {
    let configurations = try YouTubeStreamKeyConfigurationStore().load()
    let landscape = configurations.first { $0.id == workspaceSession.landscapeYouTubeLiveStreamID }
    let portrait = configurations.first { $0.id == workspaceSession.portraitYouTubeLiveStreamID }
    let destinations: YouTubeRTMPSDestinations
    switch output.youtubeIngestMode {
    case .landscapeRtmps:
      guard let landscape else { throw WorkspaceV4YouTubeOutputError.missingLandscapeStreamKey }
      destinations = try YouTubeRTMPSDestinations(landscape: landscape.destination())
    case .portraitRtmps:
      guard let portrait else { throw WorkspaceV4YouTubeOutputError.missingPortraitStreamKey }
      destinations = try YouTubeRTMPSDestinations(portrait: portrait.destination())
    case .dualRtmps:
      guard let landscape else { throw WorkspaceV4YouTubeOutputError.missingLandscapeStreamKey }
      guard let portrait else { throw WorkspaceV4YouTubeOutputError.missingPortraitStreamKey }
      destinations = try YouTubeRTMPSDestinations(
        landscape: landscape.destination(), portrait: portrait.destination())
    default:
      throw WorkspaceV4YouTubeOutputError.unsupportedIngestMode
    }
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
    return DefaultLocalOutputService(fileManager: .default).defaultBaseDirectory
  }

  private func requestRequiredCaptureAccess(
    configurations: [ProgramRuntimeConfiguration]
  ) async throws {
    if configurations.contains(where: { configuration in
      configuration.composite.steps.contains { $0.component.definition.usesInputCameraDevice }
    }), await requestCaptureAccess(for: .video) == false {
      throw CameraCaptureServiceError.cameraAccessDenied
    }
    if configurations.contains(where: { configuration in
      configuration.audioChannels.contains { $0.component.definition.usesInputAudioDevice }
    }), await requestCaptureAccess(for: .audio) == false {
      throw CameraCaptureServiceError.microphoneAccessDenied
    }
  }

  private func requestCaptureAccess(for mediaType: AVMediaType) async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: mediaType) {
    case .authorized:
      true
    case .notDetermined:
      await withCheckedContinuation { continuation in
        AVCaptureDevice.requestAccess(for: mediaType) { continuation.resume(returning: $0) }
      }
    case .denied, .restricted:
      false
    @unknown default:
      false
    }
  }
}

private enum WorkspaceV4YouTubeOutputError: LocalizedError {
  case missingLandscapeStreamKey
  case missingPortraitStreamKey
  case unsupportedIngestMode

  var errorDescription: String? {
    switch self {
    case .missingLandscapeStreamKey:
      "Select a Landscape Stream Key before starting YouTube output."
    case .missingPortraitStreamKey:
      "Select a Portrait Stream Key before starting YouTube output."
    case .unsupportedIngestMode:
      "The selected YouTube ingest mode is not available for Version 4 Workspaces yet."
    }
  }
}
