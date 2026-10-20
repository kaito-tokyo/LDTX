// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
@testable import LDTXProgramRuntime
@testable import LDTXWorkspaceAppletService
import Synchronization
import Testing

/// Exercises the native monitor coordinator without opening hardware. Core Audio
/// is the SUT's platform dependency, so this belongs in MediumTests.
@Suite
@MainActor
struct WorkspaceAudioCoordinatorIntegrationTestSuite {
  @Test(arguments: [true, false])
  func sharedPhysicalInputKeepsLogicalMonitorGains(secondConnected: Bool) {
    let engine = WorkspaceAudioEngine(hardwareEnabled: false)
    let monitor = ProgramAudioMonitor(engine: engine)
    let channels = [
      ProgramAudioChannel(id: "first", component: .inputAudioDevice(.init())),
      ProgramAudioChannel(id: "second", component: .inputAudioDevice(.init())),
    ]
    let keys = channels.map { channels.audioChannelKey(for: $0) }
    let mappings = Dictionary(
      uniqueKeysWithValues: channels.map {
        (channels.inputAudioDeviceMappingKey(for: $0), "shared-physical-input")
      })
    monitor.restart(
      audioChannels: channels, inputAudioDeviceMappings: mappings,
      programPreferences: .init(),
      inputPassthroughChannelKeys: Set(secondConnected ? keys : [keys[0]]),
      peakMeter: .init(), completionHandler: { _ in })
    defer { monitor.stop() }
    let original = engine.monitorRouteValues
    #expect(original.count == 2)
    #expect(original[0].input == original[1].input)
    var preferences = ProgramPreferences()
    preferences.audioChannelGainsByName = [keys[0]: 0.25, keys[1]: 0.75]
    // Preference projection order must not replace the configured route order.
    monitor.updateValues(audioChannels: channels.reversed(), preferences: preferences)
    let updated = engine.monitorRouteValues
    #expect(updated.map(\.gain) == [0.25, 0.75])
    #expect(updated.map(\.connected) == original.map(\.connected))
    #expect(updated.map(\.input) == original.map(\.input))
  }

  @Test func outputDevicePreferenceNotifiesOwnerOnlyWhenDeviceChanges() throws {
    let suite = "monitor-preference-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let engine = WorkspaceAudioEngine(hardwareEnabled: false, defaults: defaults)
    let notifications = Mutex(0)
    engine.setMonitorDeviceChangeHandler { notifications.withLock { $0 += 1 } }
    defaults.set(1, forKey: "unrelated")
    engine.notifyMonitorDeviceChange()
    #expect(notifications.withLock { $0 } == 0)
    defaults.set("new-output", forKey: WorkspaceAudioEngine.outputDevicePreferenceKey)
    engine.notifyMonitorDeviceChange()
    engine.notifyMonitorDeviceChange()
    #expect(notifications.withLock { $0 } == 1)
  }

  @Test func monitorValueUpdatesDoNotConstructNewInputs() {
    let engine = WorkspaceAudioEngine(hardwareEnabled: false)
    let monitor = ProgramAudioMonitor(engine: engine)
    let first = ProgramAudioChannel(id: "first", component: .inputAudioDevice(.init()))
    let second = ProgramAudioChannel(id: "second", component: .inputAudioDevice(.init()))
    let channels = [first, second]
    monitor.restart(
      audioChannels: [first],
      inputAudioDeviceMappings: [
        channels.inputAudioDeviceMappingKey(for: first): "existing-input",
        channels.inputAudioDeviceMappingKey(for: second): "unconfigured-input",
      ], programPreferences: .init(), inputPassthroughChannelKeys: [], peakMeter: .init(),
      completionHandler: { _ in })
    #expect(engine.existingInput(uid: "existing-input") != nil)
    #expect(engine.existingInput(uid: "unconfigured-input") == nil)
    monitor.updateValues(audioChannels: channels, preferences: .init())
    #expect(engine.existingInput(uid: "unconfigured-input") == nil)
    monitor.stop()
  }

  @Test func consecutiveRestartsJoinWithoutCancellingTheirPredecessor() async {
    let capture = WorkspaceCaptureSessionCoordinator(
      captureServiceFactory: { preconditionFailure("No camera expected") },
      audioCaptureServiceFactory: { preconditionFailure("No audio expected") })
    let coordinator = WorkspaceAudioCoordinator(captureSessionCoordinator: capture)
    func restart() -> Task<Result<Void, NSError>, Never> {
      coordinator.restart(
        audioChannels: [], inputAudioDeviceMappings: [:],
        programPreferences: .init(), inputPassthroughChannelKeys: [], shouldRemainRunning: { true },
        failureHandler: { _ in Issue.record("Unexpected failure") },
        errorHandler: { _ in Issue.record("Unexpected failure") })
    }
    let first = restart()
    let second = restart()
    guard case .success = await first.value, case .success = await second.value else {
      Issue.record("New restart must not cancel accepted work")
      return
    }
    #expect(!first.isCancelled)
    await coordinator.stopAndReset()
  }

  @Test func stopJoinsAndCancelsRestartThatHasNotStarted() async {
    let capture = WorkspaceCaptureSessionCoordinator(
      captureServiceFactory: { preconditionFailure("No camera expected") },
      audioCaptureServiceFactory: { preconditionFailure("No audio capture expected") })
    let coordinator = WorkspaceAudioCoordinator(captureSessionCoordinator: capture)
    let checks = Mutex(0)
    let restart = coordinator.restart(
      audioChannels: [], inputAudioDeviceMappings: [:], programPreferences: .init(),
      inputPassthroughChannelKeys: [],
      shouldRemainRunning: {
        checks.withLock { $0 += 1 }
        return true
      },
      failureHandler: { _ in Issue.record("Unexpected capture failure") },
      errorHandler: { _ in Issue.record("Unexpected restart failure") })
    await coordinator.stopAndReset()
    let result = await restart.value
    guard case .failure = result else {
      Issue.record("Cancelled restart must not report success")
      return
    }
    #expect(restart.isCancelled)
    #expect(checks.withLock { $0 } == 0)
    #expect(coordinator.isFullyStopped())
  }
}
