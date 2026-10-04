// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
import LDTXProgram
import LDTXProgramRuntime
import LDTXProtos
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
  private let physicalDeviceIDsProvider: () -> [UInt64: WorkspacePhysicalDeviceID]
  private let localStateProvider: () -> WorkspaceLocalState
  private let selectProgramHandler: (UInt64?) -> Void
  public private(set) var landscapeRuntime: ProgramRuntime?
  public private(set) var portraitRuntime: ProgramRuntime?
  let internalIDGenerator = WorkspaceInternalIDGenerator()
  public private(set) var recordingState: WorkspaceRecordingState = .idle
  public private(set) var visionFailureMessages: [UInt64: String] = [:]
  public private(set) var visionResults: [UInt64: String] = [:]
  var visionArchiveHandler: ((UInt64, CIImage, String) -> Void)?
  var visionArchiveTimelineProvider: (() -> UInt64?)?

  public init(
    persistence: WorkspaceV4PersistenceCoordinator,
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    physicalDeviceIDs: @escaping () -> [UInt64: WorkspacePhysicalDeviceID] = { [:] },
    localState: @escaping () -> WorkspaceLocalState = { .init() },
    selectProgram: @escaping (UInt64?) -> Void = { _ in }
  ) {
    self.persistenceCoordinator = persistence
    self.captureSessionCoordinator = captureSessionCoordinator
    self.physicalDeviceIDsProvider = physicalDeviceIDs
    self.localStateProvider = localState
    self.selectProgramHandler = selectProgram
  }

  var physicalDeviceIDs: [UInt64: WorkspacePhysicalDeviceID] { physicalDeviceIDsProvider() }

  public var workspace: WorkspaceV4Bundle { persistenceCoordinator.workspace }
  public var definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4 { workspace.definition }
  public var preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4 { workspace.preferences }
  public var url: URL? { persistenceCoordinator.url }

  public func shutdown() {
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
  var selectedProgramInternalID: UInt64? {
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
    updateRuntime(landscapeRuntime, target: .landscape)
    updateRuntime(portraitRuntime, target: .portrait)
  }

  public func removeProgram(internalID: UInt64) throws {
    var workspace = self.workspace
    workspace.definition.programs.removeAll { $0.internalID == internalID }
    guard workspace.definition.programs.count != self.workspace.definition.programs.count else {
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
    for input in workspace.definition.inputDevices {
      switch input.definition {
      case .videoDevice(let device):
        if case .avCaptureDevice(let id)? = physicalDeviceIDsProvider()[device.internalID],
          !id.isEmpty
        {
          videoCameraIDs.insert(id)
        }
      case .audioDevice(let device):
        if case .coreAudioDevice(let id)? = physicalDeviceIDsProvider()[device.internalID],
          !id.isEmpty
        {
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
    guard
      case .avCaptureDevice(let physicalDeviceID)? = physicalDeviceIDsProvider()[inputID]
    else { throw WorkspaceVisionFeatureError.inputDeviceHasNoPhysicalCamera }
    guard let frame = captureSessionCoordinator.latestVisionFrame(forCameraID: physicalDeviceID)
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
  case invalidAudioChannelGain
  case invalidAudioMasterVolume
  case missingVideoLayer(UInt64)
  case missingProgram(UInt64)
  case missingVision(UInt64)
  case missingResource(UInt64)
}
