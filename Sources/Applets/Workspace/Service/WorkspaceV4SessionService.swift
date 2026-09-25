// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletStore
import OSLog
import Observation

/// Persistent diagnostics for Version 4 Workspace lifecycle operations. These
/// records remain available in release builds after a Workspace closes.
private let workspaceV4OperationLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "WorkspaceOperation"
)

/// Owns one open Version 4 Workspace. This is the application-session
/// boundary for V4 documents and projects directly from v4 documents.
@MainActor
@Observable
public final class WorkspaceV4SessionService {
  private(set) var persistence: WorkspaceV4PersistenceCoordinator
  public let captureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  private var runtimes: [ProgramCanvasRole: ProgramRuntime] = [:]
  var visionArchiveHandler: ((UInt64, CIImage, String) -> Void)?
  var visionArchiveTimelineProvider: (() -> UInt64?)?

  public init(
    persistence: WorkspaceV4PersistenceCoordinator,
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  ) {
    self.persistence = persistence
    self.captureSessionCoordinator = captureSessionCoordinator
  }

  public convenience init(captureSessionCoordinator: WorkspaceCaptureSessionCoordinator) {
    self.init(
      persistence: WorkspaceV4PersistenceCoordinator(),
      captureSessionCoordinator: captureSessionCoordinator
    )
  }

  public var store: WorkspaceV4Store { persistence.store }
  public var url: URL? { persistence.url }
  public var isDirty: Bool { store.isDirty }
  public var selectedProgramInternalID: UInt64? {
    get { persistence.selectedProgramInternalID }
    set {
      persistence.selectedProgramInternalID = newValue
      updateRuntimes()
    }
  }

  public func physicalVideoDeviceID(for inputDeviceInternalID: UInt64) -> String? {
    persistence.physicalVideoDeviceID(for: inputDeviceInternalID)
  }

  public func setPhysicalVideoDeviceID(_ physicalDeviceID: String?, for inputDeviceInternalID: UInt64) {
    persistence.setPhysicalVideoDeviceID(physicalDeviceID, for: inputDeviceInternalID)
    updateRuntimes()
  }

  public func physicalAudioDeviceID(for inputDeviceInternalID: UInt64) -> String? {
    persistence.physicalAudioDeviceID(for: inputDeviceInternalID)
  }

  public func setPhysicalAudioDeviceID(_ physicalDeviceID: String?, for inputDeviceInternalID: UInt64) {
    persistence.setPhysicalAudioDeviceID(physicalDeviceID, for: inputDeviceInternalID)
    updateRuntimes()
  }

  public func synchronizesLandscapeMixToPortrait(for programInternalID: UInt64) -> Bool {
    persistence.synchronizesLandscapeMixToPortrait(for: programInternalID)
  }

  public func setSynchronizesLandscapeMixToPortrait(_ enabled: Bool, for programInternalID: UInt64) {
    persistence.setSynchronizesLandscapeMixToPortrait(enabled, for: programInternalID)
    updateRuntimes()
  }

  public func monitorsAudioInputDevice(_ inputDeviceInternalID: UInt64) -> Bool {
    persistence.monitorsAudioInputDevice(inputDeviceInternalID)
  }

  public func setMonitorsAudioInputDevice(_ enabled: Bool, for inputDeviceInternalID: UInt64) {
    persistence.setMonitorsAudioInputDevice(enabled, for: inputDeviceInternalID)
  }

  public var landscapeYouTubeLiveStreamID: String? {
    persistence.landscapeYouTubeLiveStreamID
  }

  public func setLandscapeYouTubeLiveStreamID(_ streamID: String?) {
    persistence.setLandscapeYouTubeLiveStreamID(streamID)
  }

  public var portraitYouTubeLiveStreamID: String? {
    persistence.portraitYouTubeLiveStreamID
  }

  public func setPortraitYouTubeLiveStreamID(_ streamID: String?) {
    persistence.setPortraitYouTubeLiveStreamID(streamID)
  }

  public var visionFailureMessages: [UInt64: String] { store.visionFailureMessages }
  public var visionResults: [UInt64: String] { store.visionResults }

  public func installRuntime(_ runtime: ProgramRuntime, role: ProgramCanvasRole) {
    runtimes[role] = runtime
    updateRuntime(role: role)
  }

  public func runtime(for role: ProgramCanvasRole) -> ProgramRuntime? { runtimes[role] }

  public func updateRuntimes() {
    for role in ProgramCanvasRole.allCases { updateRuntime(role: role) }
  }

  public func removeProgram(internalID: UInt64) throws {
    try store.removeProgram(internalID: internalID)
    if selectedProgramInternalID == internalID {
      selectedProgramInternalID = store.workspace.definition.definition.programs.first?.internalID
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
        definition: store.workspace.definition.definition,
        preferences: store.workspace.preferences.preferences,
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
    persistence.runtimeLocalState
  }

  public func create(displayName: String) throws {
    persistence.releaseActiveLock()
    persistence = try WorkspaceV4PersistenceCoordinator(
      store: WorkspaceV4Store(cleanNamed: displayName)
    )
    updateRuntimes()
    workspaceV4OperationLogger.notice(
      "workspace-v4 created displayName=\(displayName, privacy: .public)"
    )
  }

  public func open(at packageURL: URL) throws {
    let lock = try persistence.acquireLock(at: packageURL)
    var activated = false
    defer {
      if !activated { persistence.releaseLock(lock) }
    }
    let store = try persistence.load(at: packageURL)
    persistence.replace(store: store, url: packageURL)
    persistence.activateLock(lock)
    activated = true
    updateRuntimes()
    workspaceV4OperationLogger.notice(
      "workspace-v4 opened package=\(packageURL.path, privacy: .public)"
    )
  }

  public func reloadFromDisk() throws {
    guard let packageURL = persistence.url else { return }
    // Keep the active lock while loading and replacing the in-memory state.
    // Releasing it first creates a window in which another process can replace
    // the package before this workspace has reloaded it.
    let store = try persistence.load(at: packageURL)
    persistence.replace(store: store, url: packageURL)
    updateRuntimes()
  }

  public func save(to packageURL: URL) throws {
    let normalizedURL = persistence.packageURL(for: packageURL)
    if normalizedURL.standardizedFileURL != persistence.url?.standardizedFileURL {
      let fileManager = FileManager.default
      let destinationExisted = fileManager.fileExists(atPath: normalizedURL.path)
      let lock = try persistence.acquireLock(at: normalizedURL, createsPackageDirectory: true)
      var activated = false
      defer {
        if !activated {
          persistence.releaseLock(lock)
          if !destinationExisted,
            fileManager.fileExists(atPath: normalizedURL.path)
          {
            try? fileManager.removeItem(at: normalizedURL)
          }
        }
      }
      try persistence.save(store, to: normalizedURL, resourcesSourceURL: persistence.url)
      persistence.activateLock(lock)
      activated = true
      updateRuntimes()
      workspaceV4OperationLogger.notice(
        "workspace-v4 saved package=\(normalizedURL.path, privacy: .public) saveAs=true"
      )
      return
    }
    try persistence.save(store, to: normalizedURL)
    workspaceV4OperationLogger.notice(
      "workspace-v4 saved package=\(normalizedURL.path, privacy: .public) saveAs=false"
    )
  }

  public func synchronizeCaptureInputs(
    availableCameraIDs: Set<String>,
    completionHandler: @escaping @Sendable (Set<String>) -> Void
  ) {
    var videoCameraIDs: Set<String> = []
    var audioDeviceIDs: Set<String> = []
    for input in store.workspace.definition.definition.inputDevices {
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
    let canvas = store.workspace.definition.definition.canvasConfiguration
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
        self.store.workspace.definition.definition.visions.compactMap {
          wrapper -> Ldtx_Workspace_V4_OcrVision? in
          guard case .ocrVision(let vision)? = wrapper.definition,
            vision.internalID == internalID
          else { return nil }
          return vision
        }.first
      },
      frameForVision: { vision in try self.frameForVision(vision) },
      reportResult: { internalID, result in
        self.store.visionResults[internalID] = result
        self.store.visionFailureMessages.removeValue(forKey: internalID)
      },
      reportFailure: { internalID, error in
        self.store.visionResults.removeValue(forKey: internalID)
        self.store.visionFailureMessages[internalID] = error.localizedDescription
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

  public func close() {
    persistence.releaseActiveLock()
    workspaceV4OperationLogger.notice(
      "workspace-v4 closed package=\(self.url?.path ?? "unsaved", privacy: .public)"
    )
  }
}
