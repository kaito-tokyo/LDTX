// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXProgram
import LDTXWorkspaceAppletStore
import LDTXWorkspaceAppletService
import SwiftUI

@MainActor
public enum WorkspaceWindowUIFactory {
  public static func makeSplit(
    session: WorkspaceV4SessionService,
    recordingSession: WorkspaceV4RecordingSession,
    audioCoordinator: WorkspaceAudioCoordinator,
    visionFeature: any WorkspaceV4VisionFeatureProviding
  ) -> PaneSplitViewController {
    let synchronizeVision = { [weak session, weak visionFeature] in
      guard let session, let visionFeature else { return }
      visionFeature.synchronize(
        visions: session.definition.visions,
        context: session.visionFeatureContext)
    }

    return PaneSplitViewController(
      sidebar: paneHost(
        WorkspaceV4Sidebar(
          store: session.store,
          session: session,
          synchronizeVision: synchronizeVision,
          submitVision: { [weak session, weak visionFeature] id in
            guard let session, let visionFeature else { return }
            visionFeature.submit(visionInternalID: id, context: session.visionFeatureContext)
          },
          refreshOutputMix: { [weak recordingSession] in
            recordingSession?.updateMixPreferences()
          },
          outputIsActive: { [weak recordingSession] in recordingSession?.isRecording ?? false },
          synchronizeAudioMonitor: { [weak session, weak audioCoordinator] in
            guard let session, let audioCoordinator else { return }
            synchronizeV4AudioMonitor(session: session, audioCoordinator: audioCoordinator)
          })),
      content: paneHost(
        WorkspaceV4Content(
          store: session.store,
          session: session,
          recordingSession: recordingSession,
          saveBeforeStartingOutput: { [weak session] () throws -> Bool in
            guard let session, let url = session.url else { return false }
            if session.store.isDirty { try session.save(to: url) }
            return !session.store.isDirty
          },
          synchronizeVision: synchronizeVision,
          synchronizeAudioMonitor: { [weak session, weak audioCoordinator] in
            guard let session, let audioCoordinator else { return }
            synchronizeV4AudioMonitor(session: session, audioCoordinator: audioCoordinator)
          })),
      inspector: paneHost(
        WorkspaceV4Inspector(
          store: session.store, session: session, recordingSession: recordingSession)),
      sidebarCanCollapse: true)
  }
}

@MainActor
public func synchronizeV4AudioMonitor(
  session: WorkspaceV4SessionService,
  audioCoordinator: WorkspaceAudioCoordinator
) {
  guard let programInternalID = session.store.selectedProgramInternalID,
    let projection = try? session.runtimeProjection(
      programInternalID: programInternalID,
      role: .landscape)
  else {
    Task { await audioCoordinator.stopAndReset() }
    return
  }
  let audioDeviceIDs = Dictionary(
    uniqueKeysWithValues:
      session.store.definition.inputDevices.compactMap { input -> (String, String)? in
        guard case .audioDevice(let device)? = input.definition,
          let physicalID = session.physicalAudioDeviceID(for: device.internalID)
        else { return nil }
        return ("v4-\(device.internalID)", physicalID)
      })
  let monitoredKeys = Set(
      session.store.definition.inputDevices.compactMap { input -> String? in
      guard case .audioDevice(let device)? = input.definition,
        session.store.monitorsAudioInputDevice(device.internalID)
      else { return nil }
      return "v4-\(device.internalID)"
    })
  var preferences = projection.preferences
  preferences.masterVolume = ProgramPreferences.linearAudioChannelGain(
    fromDecibels: session.store.preferences.monitorVolume)
  _ = audioCoordinator.restart(
    audioChannels: projection.configuration.audioChannels,
    inputAudioDeviceMappings: audioDeviceIDs,
    programPreferences: preferences,
    inputPassthroughChannelKeys: monitoredKeys,
    shouldRemainRunning: { true },
    failureHandler: { _ in },
    errorHandler: { _ in })
}
