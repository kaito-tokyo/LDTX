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

  @Test("opens a package while model edits remain in memory")
  func opensV4PackageWithoutSavingRuntimeEdits() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Unite.ldtxworkspace")
    let capture = WorkspaceCaptureSessionCoordinator()
    let runtime = try makeRuntime(capture: capture)
    let programID = try runtime.addProgram(displayName: "Main")

    try WorkspaceDocumentPackage.write(runtime.workspace, to: packageURL, createsPackage: true)
    runtime.persistenceCoordinator.setDocumentURL(packageURL)
    #expect(runtime.url == packageURL)
    #expect(runtime.isDirty)

    let reopened = try makeRuntime(capture: capture)
    try reopened.persistenceCoordinator.open(at: packageURL)
    #expect(reopened.definition.programs.map(\.displayName) == ["Main"])
    #expect(reopened.selectedProgramInternalID == programID)
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
    let box = WorkspaceBox(cleanWorkspace(displayName: "Unite"))
    let suite = "WorkspaceRuntimeAssignments.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let appletData = WorkspaceAppletData(userDefaults: defaults)
    let url = URL(fileURLWithPath: "/tmp/WorkspaceWindowRuntimeTests-\(UUID()).ldtxworkspace")
    let coordinator = WorkspaceV4PersistenceCoordinator(
      workspaceSnapshot: { box.workspace }, workspaceIsDirty: { box.isDirty },
      replaceWorkspace: { try box.replace($0) }, url: url)
    let windowRuntime = WorkspaceWindowRuntime(
      persistence: coordinator, captureSessionCoordinator: capture,
      physicalDeviceIDs: { appletData.physicalDeviceIDsByInputDeviceInternalID },
      localState: { appletData.state(for: url) },
      selectProgram: { internalID in
        appletData.updateState(for: url) { $0.selectedProgramInternalID = internalID }
      })
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

    appletData.setPhysicalDeviceID(.avCaptureDevice(uniqueID: "camera-id"), for: videoInputID)
    windowRuntime.updateRuntimes()

    #expect(
      appletData.physicalDeviceID(for: videoInputID)
        == .avCaptureDevice(uniqueID: "camera-id"))
    #expect(
      programRuntime.programState.read { $0?.cameraIDsByInputKey }
        == ["v4-\(videoInputID)": "camera-id"])
  }

  @Test("uses local state at the document-provided URL")
  func usesLocalStateAtDocumentProvidedURL() throws {
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
    let coordinator = WorkspaceV4PersistenceCoordinator(
      workspaceSnapshot: { box.workspace }, workspaceIsDirty: { box.isDirty },
      replaceWorkspace: { try box.replace($0) },
      url: originalURL)
    let runtime = WorkspaceWindowRuntime(
      persistence: coordinator,
      captureSessionCoordinator: capture,
      physicalDeviceIDs: { appletData.physicalDeviceIDsByInputDeviceInternalID },
      localState: { coordinator.url.map { appletData.state(for: $0) } ?? .init() })
    let videoInputID = try runtime.addVideoInputDevice(displayName: "Camera")
    appletData.setPhysicalDeviceID(.avCaptureDevice(uniqueID: "camera-id"), for: videoInputID)

    let destination = rootURL.appendingPathComponent("Unite.ldtxworkspace")
    appletData.copyState(from: originalURL, to: destination)
    runtime.persistenceCoordinator.setDocumentURL(destination)

    #expect(
      appletData.physicalDeviceID(for: videoInputID)
        == .avCaptureDevice(uniqueID: "camera-id"))
    #expect(
      appletData.physicalDeviceID(for: videoInputID)
        == .avCaptureDevice(uniqueID: "camera-id"))
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

  @Test("joins concurrent recording-stop requests")
  func joinsConcurrentRecordingStops() async throws {
    let runtime = try makeRuntime(capture: WorkspaceCaptureSessionCoordinator())
    let recording = WorkspaceV4RecordingSession(windowRuntime: runtime)
    recording.state = .recording
    var transitions: [WorkspaceRecordingState] = []
    recording.stateDidChange = { transitions.append($0) }

    async let first: Void = recording.stop()
    async let second: Void = recording.stop()
    await first
    await second

    #expect(transitions == [.stopping, .idle])
    #expect(recording.state == .idle)
  }

  @Test("pause finalizes output and permits a new start")
  func pausesAndRestartsOutput() async throws {
    let runtime = try makeRuntime(capture: WorkspaceCaptureSessionCoordinator())
    let recording = WorkspaceV4RecordingSession(windowRuntime: runtime)
    recording.state = .recording
    var transitions: [WorkspaceRecordingState] = []
    recording.stateDidChange = { transitions.append($0) }
    async let first: Void = recording.pause()
    async let second: Void = recording.pause()
    await first
    await second
    #expect(transitions == [.pausing, .paused])
    #expect(!recording.isRecording)
    await recording.start()
    #expect(recording.state == .failed("Select a Program before starting recording."))
    recording.state = .paused
    await recording.stop()
    #expect(recording.state == .idle)
  }

  @Test("stop joins Pause finalization and leaves the session idle")
  func stopsWhilePausing() async throws {
    let runtime = try makeRuntime(capture: WorkspaceCaptureSessionCoordinator())
    let recording = WorkspaceV4RecordingSession(windowRuntime: runtime)
    recording.state = .recording
    var stopTask: Task<Void, Never>?
    recording.stateDidChange = { value in
      if value == .pausing {
        stopTask = Task { @MainActor in await recording.stop() }
      }
    }
    await recording.pause()
    await stopTask?.value
    #expect(recording.state == .idle)
  }

  @Test("stopping preserves an output failure")
  func preservesOutputFailure() async throws {
    let runtime = try makeRuntime(capture: WorkspaceCaptureSessionCoordinator())
    let recording = WorkspaceV4RecordingSession(windowRuntime: runtime)
    recording.state = .failed("Output failed")
    await recording.pause()
    #expect(recording.state == .failed("Output failed"))
    await recording.stop()
    #expect(recording.state == .failed("Output failed"))
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
    var localState = WorkspaceLocalState()
    let coordinator = WorkspaceV4PersistenceCoordinator(
      workspaceSnapshot: { box.workspace }, workspaceIsDirty: { box.isDirty },
      replaceWorkspace: { try box.replace($0) },
      url: URL(fileURLWithPath: "/tmp/WorkspaceWindowRuntimeTests-\(UUID()).ldtxworkspace"))
    return WorkspaceWindowRuntime(
      persistence: coordinator, captureSessionCoordinator: capture,
      localState: { localState },
      selectProgram: { localState.selectedProgramInternalID = $0 })
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
