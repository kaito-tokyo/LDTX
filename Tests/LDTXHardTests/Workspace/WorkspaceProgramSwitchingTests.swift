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
    var workspace = WorkspaceV4Bundle(definition: definition, preferences: .init())
    var local = WorkspaceLocalState(recordingFolderPath: directory.path)
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
    runtime.installRuntimes(landscape: landscape, portrait: portrait)
    let first = try runtime.addProgram(displayName: "First")
    let second = try runtime.addProgram(displayName: "Second")
    var color = Ldtx_Workspace_V4_ExtendedSrgbColor()
    color.blue = 1
    color.alpha = 1
    let fill = try runtime.addSolidColorFill(displayName: "Blue", color: color)
    let clock = try runtime.addClock(displayName: "Clock")
    for target in [WorkspaceCanvasTarget.landscape, .portrait] {
      try runtime.setVideoLayerOrder([fill], forProgramInternalID: first, target: target)
      try runtime.setVideoLayerOrder([clock], forProgramInternalID: second, target: target)
    }
    let audio = try runtime.addAudioInputDevice(displayName: "Unavailable Audio")
    try runtime.setAudioChannelGain(
      .with {
        $0.numerator = -12
        $0.denominator = 1
      }, forAudioInputDeviceInternalID: audio)
    try runtime.setAudioChannelMuted(
      true, forAudioInputDeviceInternalID: audio, programInternalID: second, target: .portrait)
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
    func recordingPackages() throws -> [URL] {
      try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
      ).filter { $0.pathExtension == "ldtxrecord" }
    }
    var startedPackages = try recordingPackages()
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while startedPackages.isEmpty && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
      startedPackages = try recordingPackages()
    }
    #expect(startedPackages.count == 1)
    let package = try #require(startedPackages.first)
    try await Task.sleep(for: .milliseconds(350))
    local.selectedProgramInternalID = second
    runtime.updateRuntimes()
    try session.reconfigureProgramOutput()
    for (target, installedRuntime) in [
      (WorkspaceCanvasTarget.landscape, runtime.landscapeRuntime),
      (WorkspaceCanvasTarget.portrait, runtime.portraitRuntime),
    ] {
      let expected = try runtime.runtimeProjection(programInternalID: second, target: target)
      let actual = try #require(installedRuntime?.programState.read { $0 })
      #expect(actual.composite.steps.map(\.id) == expected.configuration.composite.steps.map(\.id))
      #expect(actual.audioChannels.count == 1)
    }
    try await Task.sleep(for: .milliseconds(350))
    #expect(session.state == .recording)
    #expect(try recordingPackages() == [package])
    #expect(runtime.landscapeRuntime === landscape)
    #expect(runtime.portraitRuntime === portrait)
    if preserveFailure {
      landscape.clearProgram()
      #expect(throws: (any Error).self) { try session.reconfigureProgramOutput() }
      #expect(session.state == .stopping)
      #expect(!session.state.canStart)
      #expect(try recordingPackages() == [package])
      await session.start()
      #expect(session.state == .stopping)
      #expect(try recordingPackages() == [package])
      await session.stop()
      #expect(session.state == .failed("The selected Program audio could not be applied."))
    } else {
      await session.stop()
      #expect(session.state == .idle)
    }
    let packages = try recordingPackages()
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
