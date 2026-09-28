// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
import LDTXProgram
import LDTXProgramRuntime
import LDTXProtos
import LDTXWorkspaceAppletData
@_exported import LDTXWorkspaceAppletInterface
import LDTXWorkspaceAppletModel
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
  private var runtimes: [ProgramCanvasRole: ProgramRuntime] = [:]
  let internalIDGenerator = WorkspaceInternalIDGenerator()
  public private(set) var recordingState: WorkspaceRecordingState = .idle
  public private(set) var visionFailureMessages: [UInt64: String] = [:]
  public private(set) var visionResults: [UInt64: String] = [:]
  var visionArchiveHandler: ((UInt64, CIImage, String) -> Void)?
  var visionArchiveTimelineProvider: (() -> UInt64?)?

  public init(
    persistence: WorkspaceV4PersistenceCoordinator,
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  ) {
    self.persistenceCoordinator = persistence
    self.captureSessionCoordinator = captureSessionCoordinator
  }

  public convenience init(
    opening url: URL,
    workspaceSnapshot: @escaping () -> WorkspaceV4Bundle,
    workspaceIsDirty: @escaping () -> Bool,
    replaceWorkspace: @escaping (WorkspaceV4Bundle) throws -> Void,
    markWorkspaceSaved: @escaping () -> Void,
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    deviceMappingAppletData: WorkspaceDeviceAppletData
  ) throws {
    let persistence = WorkspaceV4PersistenceCoordinator(
      workspaceSnapshot: workspaceSnapshot,
      workspaceIsDirty: workspaceIsDirty,
      replaceWorkspace: replaceWorkspace,
      markWorkspaceSaved: markWorkspaceSaved,
      deviceMappingAppletData: deviceMappingAppletData)
    try persistence.open(at: url)
    self.init(
      persistence: persistence, captureSessionCoordinator: captureSessionCoordinator)
  }

  public convenience init(
    workspaceSnapshot: @escaping () -> WorkspaceV4Bundle,
    workspaceIsDirty: @escaping () -> Bool,
    replaceWorkspace: @escaping (WorkspaceV4Bundle) throws -> Void,
    markWorkspaceSaved: @escaping () -> Void,
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    deviceMappingAppletData: WorkspaceDeviceAppletData
  ) {
    self.init(
      persistence: WorkspaceV4PersistenceCoordinator(
        workspaceSnapshot: workspaceSnapshot,
        workspaceIsDirty: workspaceIsDirty,
        replaceWorkspace: replaceWorkspace,
        markWorkspaceSaved: markWorkspaceSaved,
        deviceMappingAppletData: deviceMappingAppletData),
      captureSessionCoordinator: captureSessionCoordinator
    )
  }

  public var workspace: WorkspaceV4Bundle { persistenceCoordinator.workspace }
  public var definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4 { workspace.definition }
  public var preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4 { workspace.preferences }
  public var url: URL? { persistenceCoordinator.url }
  public var isDirty: Bool { persistenceCoordinator.isDirty }

  public func save() throws {
    guard let url else { throw WorkspaceV4PersistenceCoordinatorError.missingPackageURL }
    try persistenceCoordinator.save(to: url)
  }

  public func shutdown() {
    persistenceCoordinator.releaseActiveLock()
    workspaceV4OperationLogger.notice(
      "workspace-v4 closed package=\(self.url?.path ?? "unsaved", privacy: .public)"
    )
  }

  public func setRecordingState(_ state: WorkspaceRecordingState) {
    recordingState = state
  }

  func replaceWorkspace(_ workspace: WorkspaceV4Bundle) throws {
    try persistenceCoordinator.replaceWorkspaceState(workspace)
  }

  func editWorkspace(
    _ mutation: (inout WorkspaceV4Bundle) throws -> Void
  ) throws {
    var editedWorkspace = workspace
    try mutation(&editedWorkspace)
    try replaceWorkspace(editedWorkspace)
    updateRuntimes()
  }
  public var selectedProgramInternalID: UInt64? {
    get { persistenceCoordinator.selectedProgramInternalID }
    set {
      persistenceCoordinator.selectedProgramInternalID = newValue
      updateRuntimes()
    }
  }

  public func physicalVideoDeviceID(for inputDeviceInternalID: UInt64) -> String? {
    persistenceCoordinator.physicalVideoDeviceID(for: inputDeviceInternalID)
  }

  public func setPhysicalVideoDeviceID(
    _ physicalDeviceID: String?, for inputDeviceInternalID: UInt64
  ) {
    persistenceCoordinator.setPhysicalVideoDeviceID(physicalDeviceID, for: inputDeviceInternalID)
    updateRuntimes()
  }

  public func physicalAudioDeviceID(for inputDeviceInternalID: UInt64) -> String? {
    persistenceCoordinator.physicalAudioDeviceID(for: inputDeviceInternalID)
  }

  public func setPhysicalAudioDeviceID(
    _ physicalDeviceID: String?, for inputDeviceInternalID: UInt64
  ) {
    persistenceCoordinator.setPhysicalAudioDeviceID(physicalDeviceID, for: inputDeviceInternalID)
    updateRuntimes()
  }

  public func synchronizesLandscapeMixToPortrait(for programInternalID: UInt64) -> Bool {
    persistenceCoordinator.synchronizesLandscapeMixToPortrait(for: programInternalID)
  }

  public func setSynchronizesLandscapeMixToPortrait(_ enabled: Bool, for programInternalID: UInt64)
  {
    persistenceCoordinator.setSynchronizesLandscapeMixToPortrait(enabled, for: programInternalID)
    updateRuntimes()
  }

  public func monitorsAudioInputDevice(_ inputDeviceInternalID: UInt64) -> Bool {
    persistenceCoordinator.monitorsAudioInputDevice(inputDeviceInternalID)
  }

  public func setMonitorsAudioInputDevice(_ enabled: Bool, for inputDeviceInternalID: UInt64) {
    persistenceCoordinator.setMonitorsAudioInputDevice(enabled, for: inputDeviceInternalID)
  }

  public var landscapeYouTubeLiveStreamID: String? {
    persistenceCoordinator.landscapeYouTubeLiveStreamID
  }

  public func setLandscapeYouTubeLiveStreamID(_ streamID: String?) {
    persistenceCoordinator.setLandscapeYouTubeLiveStreamID(streamID)
  }

  public var portraitYouTubeLiveStreamID: String? {
    persistenceCoordinator.portraitYouTubeLiveStreamID
  }

  public func setPortraitYouTubeLiveStreamID(_ streamID: String?) {
    persistenceCoordinator.setPortraitYouTubeLiveStreamID(streamID)
  }

  public func installRuntime(_ runtime: ProgramRuntime, role: ProgramCanvasRole) {
    runtimes[role] = runtime
    updateRuntime(role: role)
  }

  public func runtime(for role: ProgramCanvasRole) -> ProgramRuntime? { runtimes[role] }

  public func updateRuntimes() {
    for role in ProgramCanvasRole.allCases { updateRuntime(role: role) }
  }

  public func removeProgram(internalID: UInt64) throws {
    var workspace = self.workspace
    workspace.definition.programs.removeAll { $0.internalID == internalID }
    guard workspace.definition.programs.count != self.workspace.definition.programs.count else {
      throw WorkspaceRuntimeError.missingProgram(internalID)
    }
    workspace.preferences.programPreferences.removeValue(forKey: internalID)
    try replaceWorkspace(workspace)
    if selectedProgramInternalID == internalID {
      selectedProgramInternalID = workspace.definition.programs.first?.internalID
    } else {
      updateRuntimes()
    }
  }

  private func updateRuntime(role: ProgramCanvasRole) {
    guard let runtime = runtimes[role] else { return }
    guard let selectedProgramInternalID else {
      runtime.clearProgram()
      return
    }
    guard
      let projection = try? WorkspaceV4RenderGraph.runtimeProjection(
        definition: workspace.definition,
        preferences: workspace.preferences,
        localState: runtimeLocalState,
        programInternalID: selectedProgramInternalID,
        role: role,
        timeSeconds: Float(ProcessInfo.processInfo.systemUptime)
      )
    else { return }
    runtime.updateProgram(projection.configuration)
    runtime.updateProgramPreferences(projection.preferences)
  }

  private var runtimeLocalState: WorkspaceLocalState {
    persistenceCoordinator.runtimeLocalState
  }

  public func synchronizeCaptureInputs(
    availableCameraIDs: Set<String>,
    completionHandler: @escaping @Sendable (Set<String>) -> Void
  ) {
    var videoCameraIDs: Set<String> = []
    var audioDeviceIDs: Set<String> = []
    for input in workspace.definition.inputDevices {
      switch input.definition {
      case .videoDevice(let device):
        if let id = physicalVideoDeviceID(for: device.internalID), !id.isEmpty {
          videoCameraIDs.insert(id)
        }
      case .audioDevice(let device):
        if let id = physicalAudioDeviceID(for: device.internalID), !id.isEmpty {
          audioDeviceIDs.insert(id)
        }
      case nil:
        continue
      }
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
    WorkspaceV4VisionFeatureContext(
      vision: { internalID in
        self.workspace.definition.visions.compactMap {
          wrapper -> Ldtx_Workspace_V4_OcrVision? in
          guard case .ocrVision(let vision)? = wrapper.definition,
            vision.internalID == internalID
          else { return nil }
          return vision
        }.first
      },
      frameForVision: { vision in try self.frameForVision(vision) },
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
  }

  private func frameForVision(
    _ vision: Ldtx_Workspace_V4_OcrVision
  ) throws -> WorkspaceVisionAnalysisFrame {
    guard case .inputDeviceInternalID(let inputID)? = vision.source else {
      throw WorkspaceVisionFeatureError.referencedInputDeviceMissing
    }
    guard physicalVideoDeviceID(for: inputID) != nil else {
      throw WorkspaceVisionFeatureError.inputDeviceHasNoPhysicalCamera
    }
    guard let physicalDeviceID = physicalVideoDeviceID(for: inputID),
      let frame = captureSessionCoordinator.latestVisionFrame(forCameraID: physicalDeviceID)
    else { throw WorkspaceVisionFeatureError.frameUnavailable }
    let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
    guard vision.hasRegionOfInterest else {
      return WorkspaceVisionAnalysisFrame(image: image)
    }
    let region = vision.regionOfInterest
    let extent = image.extent
    return WorkspaceVisionAnalysisFrame(
      image: image.cropped(
        to: CGRect(
          x: extent.minX + extent.width * CGFloat(region.x),
          y: extent.minY + extent.height * CGFloat(region.y),
          width: extent.width * CGFloat(region.width),
          height: extent.height * CGFloat(region.height)
        ))
    )
  }

}

extension WorkspaceWindowRuntime: WorkspaceWindowRuntimeProtocol {}

public enum WorkspaceRuntimeError: Error, Equatable, Sendable {
  case missingVideoLayer(UInt64)
  case missingProgram(UInt64)
  case missingVision(UInt64)
  case missingResource(UInt64)
}
