// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXProgramRuntime
import LDTXProtos
import LDTXWorkspaceAppletModel
@testable import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletStore
import LDTXWorkspaceBundleFormat
import Testing

@MainActor
@Suite(.serialized)
struct WorkspaceProgramSwitchingIntegrationTestSuite {
  @Test(arguments: [false, true])
  func recordingContinuesInOnePackageAfterProgramChange(preserveFailure: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.displayName = "Switch Test"
    definition.canvasConfiguration.landscapeProfileID = "sdr-landscape-1080p60"
    definition.canvasConfiguration.portraitProfileID = "sdr-portrait-1080p60"
    definition.canvasConfiguration.frameRate = 30
    definition.canvasConfiguration.landscapeVideoBitRate = 1_000_000
    definition.canvasConfiguration.portraitVideoBitRate = 1_000_000
    definition.outputConfiguration.recordsLandscape = true
    definition.outputConfiguration.recordsPortrait = true
    definition.outputConfiguration.outputFolderPath = directory.path
    var workspace = WorkspaceV4Bundle(definition: definition, preferences: .init())
    var local = WorkspaceLocalState()
    let persistence = WorkspaceV4PersistenceCoordinator(
      workspaceSnapshot: { workspace },
      replaceWorkspace: { workspace = $0 },
      url: directory.appendingPathComponent("Test.ldtxworkspace"))
    let capture = WorkspaceCaptureSessionCoordinator()
    let runtime = WorkspaceWindowRuntime(
      persistence: persistence,
      captureSessionCoordinator: capture, localState: { local },
      selectProgram: { local.selectedProgramInternalID = $0 })
    let updates = LowFrequencyUpdateRegistry()
    let landscape = ProgramRuntime(
      captureSessionCoordinator: capture, lowFrequencyUpdateRegistry: updates)
    let portrait = ProgramRuntime(
      captureSessionCoordinator: capture, lowFrequencyUpdateRegistry: updates)
    runtime.installRuntime(landscape, isPortrait: false)
    runtime.installRuntime(portrait, isPortrait: true)
    let first = try runtime.addProgram(displayName: "First")
    let second = try runtime.addProgram(displayName: "Second")
    var color = Ldtx_Workspace_V4_ExtendedSrgbColor()
    color.blue = 1
    color.alpha = 1
    let fill = try runtime.addSolidColorFill(displayName: "Blue", color: color)
    let clock = try runtime.addClock(displayName: "Clock")
    for isPortrait in [false, true] {
      try runtime.setVideoLayerOrder([fill], forProgramInternalID: first, isPortrait: isPortrait)
      try runtime.setVideoLayerOrder([clock], forProgramInternalID: second, isPortrait: isPortrait)
    }
    let audio = try runtime.addAudioInputDevice(displayName: "Unavailable Audio")
    try runtime.setAudioChannelGain(
      -12, forAudioInputDeviceInternalID: audio, programInternalID: second, isPortrait: false)
    try runtime.setAudioChannelMuted(
      true, forAudioInputDeviceInternalID: audio, programInternalID: second, isPortrait: true)
    local.selectedProgramInternalID = first
    runtime.updateRuntimes()
    landscape.startPreview()
    portrait.startPreview()
    let session = WorkspaceV4RecordingSession(windowRuntime: runtime, localState: { local })
    await session.start()
    guard session.state == .recording else {
      let state = session.state
      await session.stop()
      landscape.stopPreview()
      portrait.stopPreview()
      updates.shutdown()
      runtime.shutdown()
      Issue.record("Recording did not start: \(state)")
      return
    }
    let package = try #require(session.screenshotsDirectory?.deletingLastPathComponent())
    try await Task.sleep(for: .milliseconds(350))
    local.selectedProgramInternalID = second
    runtime.updateRuntimes()
    try session.reconfigureProgramOutput()
    for isPortrait in [false, true] {
      let expected = try runtime.runtimeProjection(
        programInternalID: second, isPortrait: isPortrait)
      let actual = try #require(runtime.runtime(isPortrait: isPortrait)?.programState.read { $0 })
      #expect(actual.composite.steps.map(\.id) == expected.configuration.composite.steps.map(\.id))
      #expect(actual.audioChannels.count == 1)
    }
    try await Task.sleep(for: .milliseconds(350))
    #expect(session.state == .recording)
    #expect(session.screenshotsDirectory?.deletingLastPathComponent() == package)
    #expect(runtime.runtime(isPortrait: false) === landscape)
    #expect(runtime.runtime(isPortrait: true) === portrait)
    if preserveFailure {
      landscape.clearProgram()
      #expect(throws: (any Error).self) { try session.reconfigureProgramOutput() }
      #expect(session.state == .stopping)
      #expect(!session.state.canStart)
      #expect(session.screenshotsDirectory?.deletingLastPathComponent() == package)
      await session.start()
      #expect(session.state == .stopping)
      #expect(session.screenshotsDirectory?.deletingLastPathComponent() == package)
      await session.stop()
      #expect(session.state == .failed("The selected Program audio could not be applied."))
    } else {
      await session.stop()
      #expect(session.state == .idle)
    }
    let packages = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "ldtxrecord" }
    #expect(packages.map { $0.resolvingSymlinksInPath() } == [package.resolvingSymlinksInPath()])
    #expect(
      FileManager.default.fileExists(
        atPath: package.appendingPathComponent("landscape.fragmented.mp4").path))
    #expect(
      FileManager.default.fileExists(
        atPath: package.appendingPathComponent("portrait.fragmented.mp4").path))
    landscape.stopPreview()
    portrait.stopPreview()
    updates.shutdown()
    runtime.shutdown()
  }
}
