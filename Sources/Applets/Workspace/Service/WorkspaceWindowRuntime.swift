// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import CoreML
import CoreVideo
import Foundation
import LDTXBackgroundSegmentation
import LDTXProgram
import LDTXProgramRuntime
import LDTXProtos
import LDTXProtosMacOSExtra
import LDTXTaskQueue
import LDTXVision
import LDTXWorkspaceAppletModel
import LDTXWorkspaceBundleFormat
import OSLog
import Observation

/// Persistent diagnostics for Version 4 Workspace lifecycle operations. These
/// records remain available in release builds after a Workspace closes.
private let workspaceV4OperationLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "WorkspaceOperation"
)

/// Projects the authoritative Workspace UI state into preview and output runtimes.
@MainActor
@Observable
public final class WorkspaceWindowRuntime {
  public let persistenceCoordinator: WorkspaceV4PersistenceCoordinator
  public let captureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  private let physicalDeviceIDsProvider: () -> [Int64: WorkspacePhysicalDeviceID]
  @ObservationIgnored private var componentFrameRenderer: VideoComponentFrameRenderer?
  private let localStateProvider: () -> WorkspaceLocalState
  private let selectProgramHandler: (Int64?) -> Void
  public private(set) var landscapeRuntime: ProgramRuntime?
  public private(set) var portraitRuntime: ProgramRuntime?
  let internalIDGenerator = WorkspaceInternalIDGenerator()
  public private(set) var recordingState: WorkspaceRecordingState = .idle
  public private(set) var visionFailureMessages: [Int64: String] = [:]
  public private(set) var visionResults: [Int64: String] = [:]
  var visionArchiveHandler: ((Int64, CIImage, String) -> Void)?
  var visionArchiveTimelineProvider: (() -> UInt64?)?

  public init(
    persistence: WorkspaceV4PersistenceCoordinator,
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    physicalDeviceIDs: @escaping () -> [Int64: WorkspacePhysicalDeviceID] = { [:] },
    localState: @escaping () -> WorkspaceLocalState = { .init() },
    selectProgram: @escaping (Int64?) -> Void = { _ in }
  ) {
    self.persistenceCoordinator = persistence
    self.captureSessionCoordinator = captureSessionCoordinator
    self.physicalDeviceIDsProvider = physicalDeviceIDs
    self.localStateProvider = localState
    self.selectProgramHandler = selectProgram
  }

  var physicalDeviceIDs: [Int64: WorkspacePhysicalDeviceID] { physicalDeviceIDsProvider() }

  public var workspace: WorkspaceV4Bundle { persistenceCoordinator.runtimeWorkspace }
  public var definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4 { workspace.definition }
  public var preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4 { workspace.preferences }
  public var url: URL? { persistenceCoordinator.url }

  public func installComponentFrameRenderer(_ renderer: VideoComponentFrameRenderer) {
    componentFrameRenderer = renderer
  }

  public func shutdown() {
    componentFrameRenderer?.retainComponents([])
    workspaceV4OperationLogger.notice(
      "workspace-v4 closed package=\(self.url?.path ?? "unsaved", privacy: .public)"
    )
  }

  public func setRecordingState(_ state: WorkspaceRecordingState) {
    let wasActive = recordingState.isOutputActive
    persistenceCoordinator.setOutputActive(state.isOutputActive)
    recordingState = state
    if wasActive, !state.isOutputActive { updateRuntimes() }
  }

  func replaceWorkspace(_ workspace: WorkspaceV4Bundle) throws {
    try persistenceCoordinator.replaceWorkspaceState(workspace)
  }

  func editWorkspace(
    _ mutation: (inout WorkspaceV4Bundle) throws -> Void
  ) throws {
    var editedWorkspace = persistenceCoordinator.workspace
    try mutation(&editedWorkspace)
    try replaceWorkspace(editedWorkspace)
    updateRuntimes()
  }
  var selectedProgramInternalID: Int64? {
    get {
      let programs = definition.programs
      guard let selectedID = localStateProvider().selectedProgramInternalID,
        programs.contains(where: { $0.internalID == selectedID })
      else { return programs.first?.internalID }
      return selectedID
    }
    set {
      selectProgramHandler(newValue)
      updateRuntimes()
    }
  }

  var appletLocalState: WorkspaceLocalState { localStateProvider() }

  public func installRuntimes(landscape: ProgramRuntime, portrait: ProgramRuntime) {
    landscapeRuntime = landscape
    portraitRuntime = portrait
    updateRuntimes()
  }

  public func updateRuntimes() {
    componentFrameRenderer?.retainComponents(
      Set(
        definition.videoComponents.compactMap {
          $0.internalID
        }))
    updateRuntime(landscapeRuntime, target: .landscape)
    updateRuntime(portraitRuntime, target: .portrait)
  }

  public func removeProgram(internalID: Int64) throws {
    var workspace = persistenceCoordinator.workspace
    workspace.definition.programs.removeAll { $0.internalID == internalID }
    guard
      workspace.definition.programs.count
        != persistenceCoordinator.workspace.definition.programs.count
    else {
      throw WorkspaceRuntimeError.missingProgram(internalID)
    }
    workspace.preferences.landscapeProgramPreferences.removeValue(forKey: internalID)
    workspace.preferences.portraitProgramPreferences.removeValue(forKey: internalID)
    try replaceWorkspace(workspace)
    if selectedProgramInternalID == internalID {
      selectProgramHandler(workspace.definition.programs.first?.internalID)
    }
    updateRuntimes()
  }

  private func updateRuntime(_ runtime: ProgramRuntime?, target: WorkspaceCanvasTarget) {
    guard let runtime else { return }
    guard let selectedProgramInternalID else {
      runtime.clearProgram()
      return
    }
    guard
      let canvas = try? WorkspaceProgramCanvasSnapshot(
        definition: workspace.definition, preferences: workspace.preferences,
        programInternalID: selectedProgramInternalID, target: target),
      let projection = try? WorkspaceV4RenderGraph.runtimeProjection(
        definition: workspace.definition, canvas: canvas,
        physicalDeviceIDs: physicalDeviceIDsProvider(),
        timeSeconds: Float(ProcessInfo.processInfo.systemUptime))
    else { return }
    runtime.updateProgram(projection.configuration)
    runtime.updateProgramPreferences(projection.preferences)
  }

  public func synchronizeCaptureInputs(
    availableCameraIDs: Set<String>,
    completionHandler: @escaping @Sendable (Set<String>) -> Void
  ) {
    var videoCameraIDs: Set<String> = []
    var audioDeviceIDs: Set<String> = []
    let assignments = physicalDeviceIDsProvider()
    for wrapper in workspace.definition.videoComponents {
      guard case .vfxSource(let source) = wrapper.videoComponent,
        case .avCaptureDevice(let id)? = assignments[source.internalID], !id.isEmpty
      else { continue }
      videoCameraIDs.insert(id)
    }
    for device in workspace.definition.audioDevices {
      guard case .coreAudioDevice(let id)? = assignments[device.internalID], !id.isEmpty
      else { continue }
      audioDeviceIDs.insert(id)
    }
    let canvas = workspace.definition.canvasConfiguration
    captureSessionCoordinator.synchronizePhysicalInputCaptures(
      videoCameraIDs: videoCameraIDs,
      audioDeviceIDs: audioDeviceIDs,
      availableCameraIDs: availableCameraIDs,
      canvasWidth: 1_920,
      canvasHeight: 1_080,
      frameRate: canvas.frameRate == 0 ? 60 : Int(canvas.frameRate),
      completionHandler: completionHandler
    )
    workspaceV4OperationLogger.notice(
      "workspace-v4 synchronized-inputs videoCount=\(videoCameraIDs.count, privacy: .public) audioCount=\(audioDeviceIDs.count, privacy: .public)"
    )
  }

  public var visionFeatureContext: WorkspaceV4VisionFeatureContext {
    var context = WorkspaceV4VisionFeatureContext(
      vision: { internalID in
        self.workspace.definition.visions.compactMap {
          wrapper -> Ldtx_Workspace_V4_OcrVision? in
          guard case .ocrVision(let vision)? = wrapper.vision,
            vision.internalID == internalID
          else { return nil }
          return vision
        }.first
      },
      frameForVision: { vision in try await self.frameForVision(vision) },
      reportResult: { internalID, result in
        self.visionResults[internalID] = result
        self.visionFailureMessages.removeValue(forKey: internalID)
      },
      reportFailure: { internalID, error in
        self.visionResults.removeValue(forKey: internalID)
        self.visionFailureMessages[internalID] = error.localizedDescription
      },
      archiveResult: { [weak self] internalID, image, output in
        self?.visionArchiveHandler?(internalID, image, output)
      },
      recordingTimelineMilliseconds: { [weak self] in
        self?.visionArchiveTimelineProvider?()
      }
    )
    context.sceneDetector = { [weak self] id in
      guard
        case .ldtxSceneDetectorVision(let vision)? =
          self?.definition.visions.first(where: { $0.internalID == id })?.vision
      else { return nil }
      return vision
    }
    context.videoComponents = definition.videoComponents
    context.reportPreparationRecovered = { [weak self] id in
      self?.visionFailureMessages.removeValue(forKey: id)
    }
    context.modelURL = { [weak self] id in self?.workspace.visionModels[id] }
    context.frameForSceneDetector = { [weak self] vision in
      guard let self else { throw WorkspaceVisionFeatureError.frameUnavailable }
      return try await frameForSceneDetector(vision)
    }
    return context
  }

  public func visionInputSize(componentID: Int64) throws -> CGSize {
    guard
      let wrapper = definition.videoComponents.first(where: {
        $0.internalID == componentID
      })
    else { throw WorkspaceVisionFeatureError.referencedVideoComponentMissing }
    var width = 1920
    var height = 1080
    switch wrapper.videoComponent {
    case .vfxSource:
      guard case .avCaptureDevice(let cameraID)? = physicalDeviceIDsProvider()[componentID]
      else { throw WorkspaceVisionFeatureError.vfxSourceHasNoPhysicalCamera }
      guard captureSessionCoordinator.latestVisionFrame(forCameraID: cameraID) != nil
      else { throw WorkspaceVisionFeatureError.frameUnavailable }
      guard let size = wrapper.renderingSize, size.width > 0, size.height > 0 else {
        throw WorkspaceVisionFeatureError.frameUnavailable
      }
      width = Int(size.width)
      height = Int(size.height)
    case .clock(let clock):
      guard clock.width.double.isFinite, clock.height.double.isFinite else {
        throw WorkspaceVisionFeatureError.frameUnavailable
      }
      width = max(1, Int((clock.width.double * 1920).rounded()))
      height = max(1, Int((clock.height.double * 1080).rounded()))
    default: break
    }
    return CGSize(width: width, height: height)
  }

  private func frameForVision(
    _ vision: Ldtx_Workspace_V4_OcrVision
  ) async throws -> WorkspaceVisionAnalysisFrame {
    try await frameForVision(
      componentID: vision.videoComponentInternalID,
      region: vision.hasRegionOfInterest ? vision.regionOfInterest : nil)
  }

  public func classify(
    vision: Ldtx_Workspace_V4_LdtxSceneDetectorVision, service: VisionImageClassifierService
  ) async throws -> String {
    let frame = try await frameForSceneDetector(vision)
    return try await service.classify(image: frame.image)
  }

  private func frameForSceneDetector(
    _ vision: Ldtx_Workspace_V4_LdtxSceneDetectorVision
  ) async throws -> WorkspaceVisionAnalysisFrame {
    guard
      let size = definition.videoComponents.first(where: {
        $0.internalID == vision.videoComponentInternalID && $0.canBeVisionInput
      })?.renderingSize, size.width > 0, size.height > 0
    else {
      throw WorkspaceVisionFeatureError.referencedVideoComponentMissing
    }
    guard
      case .avCaptureDevice(let cameraID)? =
        physicalDeviceIDsProvider()[vision.videoComponentInternalID]
    else {
      throw WorkspaceVisionFeatureError.vfxSourceHasNoPhysicalCamera
    }
    guard captureSessionCoordinator.latestVisionFrame(forCameraID: cameraID) != nil else {
      throw WorkspaceVisionFeatureError.frameUnavailable
    }
    return try await frameForVision(
      componentID: vision.videoComponentInternalID,
      region: vision.hasRegionOfInterest ? vision.regionOfInterest : nil,
      inputSize: CGSize(width: CGFloat(size.width), height: CGFloat(size.height)))
  }

  private func frameForVision(
    componentID: Int64, region: Ldtx_Workspace_V4_VisionRegionOfInterest?,
    inputSize: CGSize? = nil
  ) async throws -> WorkspaceVisionAnalysisFrame {
    let size = try inputSize ?? visionInputSize(componentID: componentID)
    let width = Int(size.width)
    let height = Int(size.height)
    guard let renderer = componentFrameRenderer else {
      throw WorkspaceVisionFeatureError.frameUnavailable
    }
    let configuration = try WorkspaceV4RenderGraph.componentConfiguration(
      definition: definition, componentID: componentID,
      physicalDeviceIDs: physicalDeviceIDsProvider(), width: width, height: height)
    let frame = try await renderer.render(componentID: componentID, configuration: configuration)
    guard !frame.isPreparingRenderResources else {
      throw WorkspaceVisionFeatureError.frameUnavailable
    }
    let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
    guard let region else { return WorkspaceVisionAnalysisFrame(image: image) }
    let resolved = try region.resolved(inputSize: (UInt32(width), UInt32(height)))
    let rect = resolved.rect(in: image.extent)
    if inputSize != nil {
      guard !rect.isNull, !rect.isEmpty,
        rect.origin.x.isFinite, rect.origin.y.isFinite,
        rect.width.isFinite, rect.height.isFinite, image.extent.contains(rect)
      else {
        throw CocoaError(
          .validationMissingMandatoryProperty,
          userInfo: [
            NSLocalizedDescriptionKey: "The region of interest must be inside the input image."
          ])
      }
    }
    return WorkspaceVisionAnalysisFrame(image: image.cropped(to: rect))
  }

}

extension WorkspaceWindowRuntime: WorkspaceWindowRuntimeProtocol {}

public enum WorkspaceRuntimeError: Error, LocalizedError, Equatable, Sendable {
  case invalidAudioChannelGain
  case invalidAudioMasterVolume
  case missingVideoLayer(Int64)
  case missingProgram(Int64)
  case missingVision(Int64)
  case missingResource(Int64)
  case resourceInUse(Int64)

  public var errorDescription: String? {
    switch self {
    case .resourceInUse:
      "Remove this Video Component from Programs, Visions, and the PTS master before deleting it."
    default: "The Workspace operation could not be completed: \(self)."
    }
  }
}
