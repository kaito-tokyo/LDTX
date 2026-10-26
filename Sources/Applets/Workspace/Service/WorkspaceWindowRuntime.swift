// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import CoreML
import CoreVideo
import Foundation
import LDTXBackgroundSegmentation
import LDTXCorelibs
import LDTXProgramRuntime
import LDTXRichText
import LDTXTaskQueue
import LDTXVision
import LDTXWorkspaceAppletModel
import OSLog
import Observation

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
  public private(set) var variableStore: [LDTXVariableKey: String]
  private var variableStoreGeneration = UUID()
  @ObservationIgnored let landscapeOverlays = ProgramOverlayProducer()
  @ObservationIgnored let portraitOverlays = ProgramOverlayProducer()
  @ObservationIgnored private var isShutDown = false
  var visionArchiveHandler: ((Int64, CIImage, String) -> Void)?
  var visionArchiveTimedHandler: ((Int64, CIImage, String, UInt64?, URL) -> Void)?
  var visionArchiveTimelineProvider: (() -> UInt64?)?
  var visionArchivePackageURL: URL?

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
    variableStore = [LDTXVariableKey: String](definition: persistence.runtimeWorkspace.definition)
    persistence.runtimeWorkspaceAdopted = { [weak self] workspace in
      guard let self else { return }
      variableStore = [LDTXVariableKey: String](definition: workspace.definition)
      variableStoreGeneration = UUID()
    }
    observeVariableChanges()
  }

  var physicalDeviceIDs: [Int64: WorkspacePhysicalDeviceID] { physicalDeviceIDsProvider() }
  var isRunning: Bool { !isShutDown }

  public var workspace: WorkspaceV4Bundle { persistenceCoordinator.runtimeWorkspace }
  public var definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4 { workspace.definition }
  public var preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4 { workspace.preferences }
  public var url: URL? { persistenceCoordinator.url }

  public func installComponentFrameRenderer(_ renderer: VideoComponentFrameRenderer) {
    componentFrameRenderer = renderer
  }

  public func shutdown() {
    isShutDown = true
    landscapeOverlays.stop()
    portraitOverlays.stop()
    componentFrameRenderer?.retainComponents([])
  }

  private static let shutdownLogger = Logger(
    subsystem: "tokyo.kaito.ldtx", category: "WorkspaceRuntimeDrain")

  public func shutdownAndWait(diagnosticID drainID: UUID = UUID()) async {
    func phase(_ name: String, completed: Bool) {
      Self.shutdownLogger.notice(
        "workspace runtime drain id=\(drainID, privacy: .public) phase=\(name, privacy: .public) completed=\(completed)"
      )
    }
    phase("rendering", completed: false)
    isShutDown = true
    for runtime in [landscapeRuntime, portraitRuntime].compactMap({ $0 }) {
      await withCheckedContinuation { continuation in
        runtime.drainRendering { continuation.resume() }
      }
    }
    phase("rendering", completed: true)
    phase("overlays", completed: false)
    for overlay in [landscapeOverlays, portraitOverlays] {
      await withCheckedContinuation { continuation in
        overlay.stop { continuation.resume() }
      }
    }
    phase("overlays", completed: true)
    phase("components", completed: false)
    if let componentFrameRenderer {
      await withCheckedContinuation { continuation in
        componentFrameRenderer.stopAndDrain { continuation.resume() }
      }
    }
    phase("components", completed: true)
  }

  private func observeVariableChanges() {
    guard !isShutDown else { return }
    withObservationTracking {
      _ = variableStore
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, !self.isShutDown else { return }
        self.refreshOverlayContent()
        self.observeVariableChanges()
      }
    }
  }

  private func refreshOverlayContent() {
    guard !isShutDown, let programID = selectedProgramInternalID else { return }
    _ = try? runtimeProjection(programInternalID: programID, target: .landscape)
    _ = try? runtimeProjection(programInternalID: programID, target: .portrait)
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
    guard !isShutDown else { return }
    componentFrameRenderer?.retainComponents(
      Set(
        definition.videoComponents.compactMap {
          $0.internalID
        }))
    updateRuntime(landscapeRuntime, target: .landscape)
    updateRuntime(portraitRuntime, target: .portrait)
  }

  public func removeProgram(
    internalID: Int64, applyRuntimeChanges: Bool = true,
    replace: ((WorkspaceV4Bundle) throws -> Void)? = nil
  ) throws {
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
    if let replace { try replace(workspace) } else { try replaceWorkspace(workspace) }
    guard applyRuntimeChanges else { return }
    if selectedProgramInternalID == internalID {
      selectProgramHandler(workspace.definition.programs.first?.internalID)
    }
    updateRuntimes()
  }

  private func updateRuntime(_ runtime: ProgramRuntime?, target: WorkspaceCanvasTarget) {
    guard let selectedProgramInternalID else {
      overlayProducer(for: target).stop()
      runtime?.clearProgram()
      return
    }
    guard
      let projection = try? runtimeProjection(
        programInternalID: selectedProgramInternalID, target: target)
    else { return }
    runtime?.updateProgram(projection.configuration)
    runtime?.updateProgramPreferences(projection.preferences)
  }

  func overlayProducer(for target: WorkspaceCanvasTarget) -> ProgramOverlayProducer {
    target.preferences == WorkspaceCanvasTarget.landscape.preferences
      ? landscapeOverlays : portraitOverlays
  }

  public func synchronizeCaptureInputs(
    availableCameraIDs: Set<String>,
    completionHandler: @escaping @Sendable (Set<String>) -> Void
  ) {
    synchronizeCaptureInputsReportingResult(availableCameraIDs: availableCameraIDs) {
      completionHandler($0.unavailableOrFailedCameraIDs)
    }
  }

  public func synchronizeCaptureInputsReportingResult(
    availableCameraIDs: Set<String>,
    completionHandler:
      @escaping @Sendable (WorkspaceCaptureSessionCoordinator.SynchronizationResult) -> Void
  ) {
    var videoCameraIDs: Set<String> = []
    var audioDeviceIDs: Set<String> = []
    let assignments = physicalDeviceIDsProvider()
    for wrapper in workspace.definition.videoComponents {
      guard case .vfxSource(let source) = wrapper.videoComponent,
        let sourceID = source.internalID,
        case .avCaptureDevice(let id)? = assignments[sourceID], !id.isEmpty
      else { continue }
      videoCameraIDs.insert(id)
    }
    for device in workspace.definition.audioDevices {
      guard let deviceID = device.internalID,
        case .coreAudioDevice(let id)? = assignments[deviceID], !id.isEmpty
      else { continue }
      audioDeviceIDs.insert(id)
    }
    let frameRate = workspace.definition.canvasConfiguration?.frameRate ?? 0
    captureSessionCoordinator.synchronizePhysicalInputCapturesReportingResult(
      videoCameraIDs: videoCameraIDs,
      audioDeviceIDs: audioDeviceIDs,
      availableCameraIDs: availableCameraIDs,
      canvasWidth: 1_920,
      canvasHeight: 1_080,
      frameRate: frameRate == 0 ? 60 : Int(frameRate),
      completionHandler: completionHandler
    )
  }

  public var visionFeatureContext: WorkspaceV4VisionFeatureContext {
    let generation = variableStoreGeneration
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
        guard self.variableStoreGeneration == generation else { return }
        self.visionResults[internalID] = result
        self.visionFailureMessages.removeValue(forKey: internalID)
      },
      reportFailure: { internalID, error in
        guard self.variableStoreGeneration == generation else { return }
        self.variableStore.reset(visionID: internalID)
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
    context.archiveTimedResult = { [weak self] internalID, image, output, timeline, package in
      self?.visionArchiveTimedHandler?(internalID, image, output, timeline, package)
    }
    context.isCurrent = { [weak self] in self?.variableStoreGeneration == generation }
    context.reportVariables = { [weak self] id, values in
      guard let self, variableStoreGeneration == generation else { return }
      applyVisionVariables(values, visionID: id)
    }
    context.sceneDetector = { [weak self] id in
      guard
        case .ldtxSceneDetectorVision(let vision)? =
          self?.definition.visions.first(where: { $0.internalID == id })?.vision
      else { return nil }
      return vision
    }
    context.recordingPackageURL = { [weak self] in self?.visionArchivePackageURL }
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
    default: break
    }
    return CGSize(width: width, height: height)
  }

  private func frameForVision(
    _ vision: Ldtx_Workspace_V4_OcrVision
  ) async throws -> WorkspaceVisionAnalysisFrame {
    guard let componentID = vision.videoComponentInternalID else {
      throw WorkspaceVisionFeatureError.referencedVideoComponentMissing
    }
    return try await frameForVision(
      componentID: componentID,
      region: vision.regionOfInterest)
  }

  public func classify(
    vision: Ldtx_Workspace_V4_LdtxSceneDetectorVision, service: VisionImageClassifierService
  ) async throws -> String {
    try await classify(
      vision: vision, frameForSceneDetector: { try await self.frameForSceneDetector(vision) },
      classifyResult: { try await service.classifyResult(image: $0) })
  }

  func classify(
    vision: Ldtx_Workspace_V4_LdtxSceneDetectorVision,
    frameForSceneDetector: () async throws -> WorkspaceVisionAnalysisFrame,
    classifyResult: (CIImage) async throws -> VisionClassificationResult
  ) async throws -> String {
    let context = visionFeatureContext
    guard let visionID = vision.internalID else { throw NanopbError.malformed }
    do {
      // Keep archive ownership tied to the request that began before any
      // asynchronous frame/model work could cross a recording Cut.
      let recordingPackageURL = context.recordingPackageURL()
      let recordingTimelineMilliseconds = context.recordingTimelineMilliseconds?()
      let frame = try await frameForSceneDetector()
      let result = try await classifyResult(frame.image)
      guard context.isCurrent() else { throw CancellationError() }
      context.reportResult(visionID, result.displayText)
      context.reportVariables(
        visionID,
        [
          .label: result.topCandidate?.label ?? "",
          .confidence: result.topCandidate.map { String($0.confidence) } ?? "0",
        ])
      if let recordingPackageURL, context.recordingPackageURL() == recordingPackageURL {
        if let archiveTimedResult = context.archiveTimedResult {
          archiveTimedResult(
            visionID, frame.image, result.displayText, recordingTimelineMilliseconds,
            recordingPackageURL)
        } else {
          context.archiveResult?(visionID, frame.image, result.displayText)
        }
      }
      return result.displayText
    } catch {
      guard context.isCurrent() else { throw CancellationError() }
      if !(error is CancellationError) { context.reportFailure(visionID, error) }
      throw error
    }
  }

  public func readVariable(_ key: LDTXVariableKey) throws -> String {
    guard let value = variableStore[key] else { throw WorkspaceVariableError.unregisteredKey(key) }
    return value
  }

  private func applyVisionVariables(_ values: [LDTXVariableItem: String], visionID: Int64) {
    let updates = Dictionary(
      uniqueKeysWithValues: values.map {
        (LDTXVariableKey(visionID: visionID, item: $0.key), $0.value)
      })
    // Result producers must publish exactly the items registered by the Definition.
    do {
      try variableStore.update(updates)
    } catch {
      assertionFailure("Invalid Vision variable update: \(error)")
    }
  }

  private func frameForSceneDetector(
    _ vision: Ldtx_Workspace_V4_LdtxSceneDetectorVision
  ) async throws -> WorkspaceVisionAnalysisFrame {
    guard
      let componentID = vision.videoComponentInternalID,
      let size = definition.videoComponents.first(where: {
        $0.internalID == componentID && $0.canBeVisionInput
      })?.renderingSize, size.width > 0, size.height > 0
    else {
      throw WorkspaceVisionFeatureError.referencedVideoComponentMissing
    }
    guard
      case .avCaptureDevice(let cameraID)? =
        physicalDeviceIDsProvider()[componentID]
    else {
      throw WorkspaceVisionFeatureError.vfxSourceHasNoPhysicalCamera
    }
    guard captureSessionCoordinator.latestVisionFrame(forCameraID: cameraID) != nil else {
      throw WorkspaceVisionFeatureError.frameUnavailable
    }
    return try await frameForVision(
      componentID: componentID,
      region: vision.regionOfInterest,
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
