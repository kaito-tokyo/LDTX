// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
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
  private var landscapeSubscription: ProgramOutputMediaHub.Subscription?
  private var portraitSubscription: ProgramOutputMediaHub.Subscription?
  private var landscapeHub: ProgramOutputMediaHub?
  private var portraitHub: ProgramOutputMediaHub?
  var state: State = .idle

  init(workspaceSession: WorkspaceV4RuntimeSession) {
    self.workspaceSession = workspaceSession
  }

  var isRecording: Bool { state == .recording || state == .starting || state == .stopping }

  func start() async {
    guard state == .idle else { return }
    guard let landscapeRuntime = workspaceSession.runtime(for: .landscape),
      let portraitRuntime = workspaceSession.runtime(for: .portrait),
      let selectedProgramInternalID = workspaceSession.selectedProgramInternalID
    else {
      state = .failed("Select a Program before starting recording.")
      return
    }
    let output = workspaceSession.store.workspace.definition.definition.outputConfiguration
    guard output.recordsLandscape || output.recordsPortrait else {
      state = .failed("Enable Landscape or Portrait recording in Output settings.")
      return
    }
    guard let landscapeConfiguration = landscapeRuntime.programState.read({ $0 }),
      let portraitConfiguration = portraitRuntime.programState.read({ $0 })
    else {
      state = .failed("The selected Program has not been rendered yet.")
      return
    }

    state = .starting
    let service: SessionRecordService
    do {
      service = try SessionRecordService(
        baseDirectory: outputDirectory(for: output),
        recordID: SessionRecordService.makeRecordID(),
        writerConfiguration: ProgramOutputEncodingConfiguration.make(configuration: landscapeConfiguration),
        portraitWriterConfiguration: ProgramOutputEncodingConfiguration.make(
          configuration: portraitConfiguration),
        audioTracks: [],
        recordsLandscape: output.recordsLandscape,
        recordsPortrait: output.recordsPortrait,
        customFields: output.recordingCustomFields,
        failureHandler: { [weak self] error in
          Task { @MainActor in await self?.fail(error) }
        })
      try service.start()
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
    installRecordingSubscriptions(
      service: service, landscapeHub: landscapeHub, portraitHub: portraitHub,
      recordsLandscape: output.recordsLandscape, recordsPortrait: output.recordsPortrait)
    activeSession = outputSession
    recordService = service
    self.landscapeHub = landscapeHub
    self.portraitHub = portraitHub

    do {
      try await start(outputSession)
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
    landscapeSubscription = nil
    portraitSubscription = nil
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
    preferences(for: programInternalID, role: .portrait)
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

  private func outputDirectory(for output: Ldtx_Workspace_V4_OutputConfiguration) -> URL {
    if output.hasOutputFolderPath, !output.outputFolderPath.isEmpty {
      return URL(fileURLWithPath: output.outputFolderPath, isDirectory: true)
    }
    return DefaultLocalOutputService(fileManager: .default).defaultBaseDirectory
  }
}
