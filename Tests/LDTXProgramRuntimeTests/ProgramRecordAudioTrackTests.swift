// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import LDTXProgramRuntime

struct ProgramRecordAudioTrackTests {
  @Test func mainRecorderFinishWaitsForConfiguration() {
    var gate = MainRecordingConfigurationGate()
    gate.beginConfiguration()

    let wasDeferred = gate.requestFinish()
    let releasesDeferredFinish = gate.completeConfiguration()
    #expect(!wasDeferred)
    #expect(releasesDeferredFinish)
    #expect(!gate.isConfiguring)
    // A deferred request is consumed exactly once.
    let nextFinishRunsNow = gate.requestFinish()
    #expect(nextFinishRunsNow)
  }

  @Test func mainRecorderFinishRunsImmediatelyAfterConfiguration() {
    var gate = MainRecordingConfigurationGate()
    gate.beginConfiguration()

    let releasedUnexpectedly = gate.completeConfiguration()
    let finishRunsNow = gate.requestFinish()
    #expect(!releasedUnexpectedly)
    #expect(finishRunsNow)
  }

  @Test func everyAudioInputMappingProducesARecordingTrack() {
    let tracks = ProgramRecordAudioTrack.make(
      deviceIDsByInputKey: [
        "commentary": "physical-mic",
        "game-audio": "physical-game-audio",
      ],
      deviceNamesByInputKey: [
        "commentary": "Commentary",
        "game-audio": "Game Audio",
      ]
    )

    #expect(Set(tracks.map(\.key)) == ["commentary", "game-audio"])
    #expect(Set(tracks.map(\.deviceID)) == ["physical-mic", "physical-game-audio"])
    #expect(Set(tracks.map(\.displayName)) == ["Commentary", "Game Audio"])
  }

  @Test func duplicateDisplayNamesStillProduceDistinctRecordingFiles() {
    let tracks = ProgramRecordAudioTrack.make(
      deviceIDsByInputKey: ["first": "device-1", "second": "device-2"],
      deviceNamesByInputKey: ["first": "Audio", "second": "Audio"]
    )

    #expect(tracks.count == 2)
    #expect(Set(tracks.map(\.fileNameStem)).count == 2)
  }

  @Test func inputAudioBacklogBoundsCaptureAdmissionAndResetsForRecovery() {
    var backlog = InputDeviceAudioRecordingBacklog()

    for _ in 0..<InputDeviceAudioRecordingBacklog.maximumQueuedSamples {
      #expect(backlog.admit() == .accepted)
    }
    #expect(backlog.queuedSampleCount == InputDeviceAudioRecordingBacklog.maximumQueuedSamples)
    #expect(backlog.admit() == .overflow)
    #expect(backlog.admit() == .dropped)

    // Recovery must not create generation after generation while the old
    // writer's queue is still full.
    let recovered = backlog.recoveredGenerationStarted()
    #expect(recovered)
    #expect(backlog.admit() == .dropped)

    // Once the worker consumes a sample, a future saturation can report one
    // new failure for the recovered writer.
    backlog.completeSample()
    #expect(backlog.admit() == .accepted)
    #expect(backlog.admit() == .overflow)

    let beganFinishing = backlog.beginFinishing()
    #expect(beganFinishing)
    #expect(backlog.admit() == .dropped)
    let recoveredWhileFinishing = backlog.recoveredGenerationStarted()
    #expect(!recoveredWhileFinishing)
  }
}
