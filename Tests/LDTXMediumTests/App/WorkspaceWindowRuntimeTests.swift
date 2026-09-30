// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgramRuntime
import LDTXProtos
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletService
@testable import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletStore
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
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
    vision.displayName = "OCR"
    vision.source = .inputDeviceInternalID(1)
    var videoInput = Ldtx_Workspace_V4_VideoInputDevice()
    videoInput.internalID = 1
    videoInput.displayName = "Camera"
    var inputWrapper = Ldtx_Workspace_V4_InputDeviceWrapper()
    inputWrapper.videoDevice = videoInput
    var wrapper = Ldtx_Workspace_V4_VisionWrapper()
    wrapper.ocrVision = vision
    try runtime.editDefinition {
      $0.inputDevices = [inputWrapper]
      $0.visions = [wrapper]
    }

    #expect(runtime.visionFeatureContext.vision(42) == vision)
  }

  @Test("saves and opens a V4 package")
  func savesAndOpensV4Package() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Unite.ldtxworkspace")
    let capture = WorkspaceCaptureSessionCoordinator()
    let runtime = try makeRuntime(capture: capture)
    let programID = try runtime.addProgram(displayName: "Main")

    try runtime.persistenceCoordinator.save(to: packageURL)
    #expect(runtime.url == packageURL)
    #expect(!runtime.isDirty)
    runtime.persistenceCoordinator.releaseActiveLock()

    let reopened = try makeRuntime(capture: capture)
    try reopened.persistenceCoordinator.open(at: packageURL)
    #expect(reopened.definition.programs.map(\.displayName) == ["Main"])
    #expect(reopened.selectedProgramInternalID == programID)
    reopened.persistenceCoordinator.releaseActiveLock()
  }

  @Test("installs the selected V4 Program directly into both runtimes")
  func installsSelectedProgramIntoRuntimes() throws {
    let capture = WorkspaceCaptureSessionCoordinator()
    let runtime = try makeRuntime(capture: capture)
    let programID = try runtime.addProgram(displayName: "Main")
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
    let first = try runtime.addProgram(displayName: "First")
    let second = try runtime.addProgram(displayName: "Second")
    runtime.selectedProgramInternalID = first

    try runtime.removeProgram(internalID: first)

    #expect(runtime.selectedProgramInternalID == second)
  }

  @Test("keeps unsaved physical camera assignments in the V4 runtime")
  func keepsUnsavedPhysicalCameraAssignmentsInRuntime() throws {
    let capture = WorkspaceCaptureSessionCoordinator()
    let windowRuntime = try makeRuntime(capture: capture)
    let videoInputID = try windowRuntime.addVideoInputDevice(displayName: "Camera")
    let programID = try windowRuntime.addProgram(displayName: "Main")
    try windowRuntime.setVideoLayerOrder(
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

  @Test("copies physical assignments into Save As local state")
  func copiesPhysicalAssignmentsIntoSaveAsLocalState() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let suiteName = "WorkspaceWindowRuntimeTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let capture = WorkspaceCaptureSessionCoordinator()
    let box = WorkspaceBox(cleanWorkspace(displayName: "Unite"))
    let appletData = WorkspaceAppletData(userDefaults: defaults)
    let originalURL = URL(
      fileURLWithPath: "/tmp/WorkspaceWindowRuntimeTests-\(UUID()).ldtxworkspace")
    let runtime = WorkspaceWindowRuntime(
      persistence: WorkspaceV4PersistenceCoordinator(
        workspaceSnapshot: { box.workspace }, workspaceIsDirty: { box.isDirty },
        replaceWorkspace: { try box.replace($0) }, markWorkspaceSaved: { box.markSaved() },
        url: originalURL,
        workspaceLocalState: { appletData.state(for: $0) },
        setWorkspaceLocalState: { appletData.setState($0, for: $1) }),
      captureSessionCoordinator: capture)
    let videoInputID = try runtime.addVideoInputDevice(displayName: "Camera")
    runtime.setPhysicalVideoDeviceID("camera-id", for: videoInputID)

    try runtime.persistenceCoordinator.save(
      to: rootURL.appendingPathComponent("Unite.ldtxworkspace"))

    let saveAsURL = rootURL.appendingPathComponent("Unite.ldtxworkspace")
    #expect(
      appletData.state(for: saveAsURL).videoInputDevicePhysicalIDs[videoInputID]
        == "camera-id")
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
    let programID = try runtime.addProgram(displayName: "Main")
    runtime.selectedProgramInternalID = programID

    await recording.start()

    #expect(recording.state == .failed("Enable recording or YouTube streaming in Output settings."))
  }

  @Test("does not start V4 YouTube output without a selected Program runtime")
  func rejectsYouTubeOutputWithoutARuntime() async throws {
    let capture = WorkspaceCaptureSessionCoordinator()
    let runtime = try makeRuntime(capture: capture)
    let recording = WorkspaceV4RecordingSession(windowRuntime: runtime)
    runtime.selectedProgramInternalID = try runtime.addProgram(displayName: "Main")
    try runtime.editDefinition { $0.outputConfiguration.streamsToYoutube = true }

    await recording.start()

    #expect(recording.state == .failed("The selected Program runtime is unavailable."))
  }

  private final class WorkspaceBox {
    var workspace: WorkspaceV4Bundle
    var saved: WorkspaceV4Bundle
    init(_ workspace: WorkspaceV4Bundle) {
      self.workspace = workspace
      self.saved = workspace
    }
    var isDirty: Bool { workspace != saved }
    func replace(_ value: WorkspaceV4Bundle) throws {
      try WorkspaceV4IntegrityValidator.validate(value)
      workspace = value
    }
    func markSaved() { saved = workspace }
  }

  private func makeRuntime(
    capture: WorkspaceCaptureSessionCoordinator
  ) throws -> WorkspaceWindowRuntime {
    let box = WorkspaceBox(cleanWorkspace(displayName: "Unite"))
    let appletData = WorkspaceAppletData()
    let coordinator = WorkspaceV4PersistenceCoordinator(
      workspaceSnapshot: { box.workspace }, workspaceIsDirty: { box.isDirty },
      replaceWorkspace: { try box.replace($0) }, markWorkspaceSaved: { box.markSaved() },
      url: URL(fileURLWithPath: "/tmp/WorkspaceWindowRuntimeTests-\(UUID()).ldtxworkspace"),
      workspaceLocalState: { appletData.state(for: $0) },
      setWorkspaceLocalState: { appletData.setState($0, for: $1) })
    return WorkspaceWindowRuntime(persistence: coordinator, captureSessionCoordinator: capture)
  }

  private func cleanWorkspace(displayName: String) -> WorkspaceV4Bundle {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.displayName = displayName
    definition.canvasConfiguration.landscapeProfileID = "sdr-landscape-1080p60"
    definition.canvasConfiguration.portraitProfileID = "sdr-portrait-1080p60"
    definition.canvasConfiguration.frameRate = 60
    definition.canvasConfiguration.landscapeVideoBitRate = 6_000_000
    definition.canvasConfiguration.portraitVideoBitRate = 6_000_000
    definition.outputConfiguration.youtubeIngestMode = .landscapeRtmps
    return WorkspaceV4Bundle(definition: definition, preferences: .init())
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
