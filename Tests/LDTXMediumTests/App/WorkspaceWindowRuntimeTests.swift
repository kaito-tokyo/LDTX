// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgramRuntime
import LDTXWorkspaceAppletData
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletService
@testable import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletStore
import LDTXYouTubeRTMPS
import Testing

@MainActor
@Suite("Workspace window runtime")
struct WorkspaceWindowRuntimeIntegrationTestSuite {
  @Test("resolves a selected single-Canvas V4 RTMPS destination")
  func resolvesSingleCanvasRTMPSDestination() throws {
    var output = Ldtx_Workspace_V4_OutputConfiguration()
    output.youtubeIngestMode = .landscapeRtmps
    let configuration = YouTubeRTMPSStreamKeyConfiguration(
      id: "landscape", name: "Landscape", streamURL: "rtmps://a.rtmp.youtube.com/live2",
      streamKey: "landscape-key")

    let destinations = try WorkspaceV4YouTubeRTMPSDestinationResolver.resolve(
      output: output, configurations: [configuration], landscapeStreamID: "landscape",
      portraitStreamID: nil)

    #expect(destinations.canvases == [.landscape])
    #expect(destinations.landscape?.streamName == "landscape-key")
  }

  @Test("uses Landscape RTMPS for an unspecified V4 ingest mode")
  func resolvesUnspecifiedIngestModeAsLandscapeRTMPS() throws {
    let output = Ldtx_Workspace_V4_OutputConfiguration()
    let configuration = YouTubeRTMPSStreamKeyConfiguration(
      id: "landscape", name: "Landscape", streamURL: "rtmps://a.rtmp.youtube.com/live2",
      streamKey: "landscape-key")

    let destinations = try WorkspaceV4YouTubeRTMPSDestinationResolver.resolve(
      output: output, configurations: [configuration], landscapeStreamID: "landscape",
      portraitStreamID: nil)

    #expect(destinations.canvases == [.landscape])
    #expect(destinations.landscape?.streamName == "landscape-key")
  }

  @Test("rejects V4 RTMPS without the selected Stream Key")
  func rejectsMissingRTMPSStreamKey() {
    var output = Ldtx_Workspace_V4_OutputConfiguration()
    output.youtubeIngestMode = .portraitRtmps

    #expect(throws: WorkspaceV4YouTubeOutputError.missingPortraitStreamKey) {
      try WorkspaceV4YouTubeRTMPSDestinationResolver.resolve(
        output: output, configurations: [], landscapeStreamID: nil, portraitStreamID: nil)
    }
  }

  @Test("resolves a V4 OCR Vision by internal ID")
  func resolvesV4VisionFromTheWindowRuntime() throws {
    let runtime = try makeRuntime(capture: WorkspaceCaptureSessionCoordinator())
    var vision = Ldtx_Workspace_V4_OcrVision()
    vision.internalID = 42
    var wrapper = Ldtx_Workspace_V4_VisionWrapper()
    wrapper.ocrVision = vision
    runtime.store.editDefinition { $0.visions = [wrapper] }

    #expect(runtime.visionFeatureContext.vision(42) == vision)
  }

  @Test("saves and opens a V4 package")
  func savesAndOpensV4Package() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Unite.ldtxworkspace")
    let capture = WorkspaceCaptureSessionCoordinator()
    let runtime = try makeRuntime(capture: capture)
    let programID = try runtime.store.addProgram(displayName: "Main")

    try runtime.persistenceCoordinator.save(to: packageURL)
    #expect(runtime.url == packageURL)
    #expect(!runtime.isDirty)
    runtime.persistenceCoordinator.releaseActiveLock()

    let reopened = try makeRuntime(capture: capture)
    try reopened.persistenceCoordinator.open(at: packageURL)
    #expect(reopened.store.workspace.definition.programs.map(\.displayName) == ["Main"])
    #expect(reopened.selectedProgramInternalID == programID)
    reopened.persistenceCoordinator.releaseActiveLock()
  }

  @Test("installs the selected V4 Program directly into both runtimes")
  func installsSelectedProgramIntoRuntimes() throws {
    let capture = WorkspaceCaptureSessionCoordinator()
    let runtime = try makeRuntime(capture: capture)
    let programID = try runtime.store.addProgram(displayName: "Main")
    let landscape = ProgramRuntime(
      captureSessionCoordinator: capture,
      lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry(),
      scheduler: ManualProgramRuntimeScheduler())
    let portrait = ProgramRuntime(
      captureSessionCoordinator: capture,
      lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry(),
      scheduler: ManualProgramRuntimeScheduler())
    runtime.installRuntime(landscape, role: .landscape)
    runtime.installRuntime(portrait, role: .portrait)
    runtime.selectedProgramInternalID = programID

    #expect(landscape.programState.read { $0?.videoLayerProgramName } == "v4-\(programID)")
    #expect(portrait.programState.read { $0?.videoLayerProgramName } == "v4-\(programID)")
  }

  @Test("selects the next Program after removing the current V4 Program")
  func selectsNextProgramAfterRemovingCurrentProgram() throws {
    let capture = WorkspaceCaptureSessionCoordinator()
    let runtime = try makeRuntime(capture: capture)
    let first = try runtime.store.addProgram(displayName: "First")
    let second = try runtime.store.addProgram(displayName: "Second")
    runtime.selectedProgramInternalID = first

    try runtime.removeProgram(internalID: first)

    #expect(runtime.selectedProgramInternalID == second)
  }

  @Test("keeps unsaved physical camera assignments in the V4 runtime")
  func keepsUnsavedPhysicalCameraAssignmentsInRuntime() throws {
    let capture = WorkspaceCaptureSessionCoordinator()
    let windowRuntime = try makeRuntime(capture: capture)
    let videoInputID = try windowRuntime.store.addVideoInputDevice(displayName: "Camera")
    let programID = try windowRuntime.store.addProgram(displayName: "Main")
    try windowRuntime.store.setVideoLayerOrder(
      [videoInputID], forProgramInternalID: programID, role: .landscape)
    let programRuntime = ProgramRuntime(
      captureSessionCoordinator: capture,
      lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry(),
      scheduler: ManualProgramRuntimeScheduler())
    windowRuntime.installRuntime(programRuntime, role: .landscape)
    windowRuntime.selectedProgramInternalID = programID

    windowRuntime.setPhysicalVideoDeviceID("camera-id", for: videoInputID)

    #expect(windowRuntime.physicalVideoDeviceID(for: videoInputID) == "camera-id")
    #expect(
      programRuntime.programState.read { $0?.cameraIDsByInputKey }
        == ["v4-\(videoInputID)": "camera-id"])
  }

  @Test("moves unsaved physical assignments into Save As local state")
  func movesUnsavedPhysicalAssignmentsIntoSaveAsLocalState() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let suiteName = "WorkspaceWindowRuntimeTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let capture = WorkspaceCaptureSessionCoordinator()
    let runtime = WorkspaceWindowRuntime(
      persistence: try WorkspaceV4PersistenceCoordinator(
        store: WorkspaceBundleStore(cleanNamed: "Unite"),
        localStateStorage: WorkspaceLocalStateStorage(userDefaults: defaults),
        deviceMappingAppletData: WorkspaceDeviceAppletData(
          userDefaults: defaults)),
      captureSessionCoordinator: capture)
    let videoInputID = try runtime.store.addVideoInputDevice(displayName: "Camera")
    runtime.setPhysicalVideoDeviceID("camera-id", for: videoInputID)

    try runtime.persistenceCoordinator.save(
      to: rootURL.appendingPathComponent("Unite.ldtxworkspace"))

    #expect(runtime.physicalVideoDeviceID(for: videoInputID) == "camera-id")
  }

  @Test("rejects V4 recording before a Program is selected")
  func rejectsRecordingWithoutASelectedProgram() async throws {
    let capture = WorkspaceCaptureSessionCoordinator()
    let runtime = try makeRuntime(capture: capture)
    let recording = WorkspaceV4RecordingSession(windowRuntime: runtime)

    await recording.start()

    #expect(recording.state == .failed("Select a Program before starting recording."))
  }

  @Test("retries V4 recording after correcting its validation")
  func retriesRecordingAfterCorrectingValidation() async throws {
    let capture = WorkspaceCaptureSessionCoordinator()
    let runtime = try makeRuntime(capture: capture)
    let recording = WorkspaceV4RecordingSession(windowRuntime: runtime)
    await recording.start()
    let programID = try runtime.store.addProgram(displayName: "Main")
    runtime.selectedProgramInternalID = programID

    await recording.start()

    #expect(recording.state == .failed("Enable recording or YouTube streaming in Output settings."))
  }

  @Test("does not start V4 YouTube output without a selected Program runtime")
  func rejectsYouTubeOutputWithoutARuntime() async throws {
    let capture = WorkspaceCaptureSessionCoordinator()
    let runtime = try makeRuntime(capture: capture)
    let recording = WorkspaceV4RecordingSession(windowRuntime: runtime)
    runtime.selectedProgramInternalID = try runtime.store.addProgram(displayName: "Main")
    runtime.store.editDefinition { $0.outputConfiguration.streamsToYoutube = true }

    await recording.start()

    #expect(recording.state == .failed("The selected Program runtime is unavailable."))
  }

  private func makeRuntime(
    capture: WorkspaceCaptureSessionCoordinator
  ) throws -> WorkspaceWindowRuntime {
    WorkspaceWindowRuntime(
      persistence: try WorkspaceV4PersistenceCoordinator(
        store: WorkspaceBundleStore(cleanNamed: "Unite"),
        deviceMappingAppletData: WorkspaceDeviceAppletData()),
      captureSessionCoordinator: capture
    )
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
