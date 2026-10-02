// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXProgramRuntime
import LDTXProtos
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletStore
import LDTXWorkspaceBundleFormat
import Observation

/// Projects the document's model into window-scoped runtimes.
@MainActor
@Observable
public final class WorkspaceV4PersistenceCoordinator {
  private let workspaceSnapshot: () -> WorkspaceV4Bundle
  private let workspaceIsDirty: () -> Bool
  private let replaceWorkspace: (WorkspaceV4Bundle) throws -> Void
  public private(set) var url: URL?

  public init(
    workspaceSnapshot: @escaping () -> WorkspaceV4Bundle,
    workspaceIsDirty: @escaping () -> Bool,
    replaceWorkspace: @escaping (WorkspaceV4Bundle) throws -> Void,
    url: URL? = nil
  ) {
    self.workspaceSnapshot = workspaceSnapshot
    self.workspaceIsDirty = workspaceIsDirty
    self.replaceWorkspace = replaceWorkspace
    self.url = url
  }

  func load(at url: URL) throws -> WorkspaceV4Bundle {
    let selectedReader = makeWorkspaceBundleReader(at: url)
    switch selectedReader {
    case .v4(let reader):
      return try reader.read()
    case .failure:
      throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
    }
  }

  var workspace: WorkspaceV4Bundle { currentWorkspace }
  var isDirty: Bool { workspaceIsDirty() }

  func replaceWorkspaceState(_ workspace: WorkspaceV4Bundle) throws {
    try replaceWorkspace(workspace)
  }

  private var currentWorkspace: WorkspaceV4Bundle { workspaceSnapshot() }

  public func open(at packageURL: URL) throws {
    try replaceWorkspace(load(at: packageURL))
    url = packageURL.standardizedFileURL
  }

  public func open(_ workspace: WorkspaceV4Bundle, at packageURL: URL) throws {
    try WorkspaceV4IntegrityValidator.validate(workspace)
    url = packageURL.standardizedFileURL
  }

  /// Synchronizes the formal NSDocument URL without changing content or save state.
  public func setDocumentURL(_ url: URL?) { self.url = url }

  /// Resolves the concrete capture hardware selected for the V4 input devices.
  /// Device assignments are app-local and never become Workspace data.
  func runtimeProjection(
    programInternalID: UInt64,
    role: ProgramCanvasRole,
    localState: WorkspaceLocalState,
    physicalDeviceIDs: [UInt64: WorkspacePhysicalDeviceID] = [:],
    timeSeconds: Float = Float(ProcessInfo.processInfo.systemUptime)
  ) throws -> WorkspaceV4RuntimeProjection {
    return try WorkspaceV4RenderGraph.runtimeProjection(
      definition: currentWorkspace.definition,
      preferences: currentWorkspace.preferences,
      localState: localState,
      physicalDeviceIDs: physicalDeviceIDs,
      programInternalID: programInternalID,
      role: role,
      timeSeconds: timeSeconds
    )
  }

  /// Installs one V4 Program directly into a shared preview or output runtime.
  func applyRuntime(
    _ runtime: ProgramRuntime,
    programInternalID: UInt64,
    role: ProgramCanvasRole,
    localState: WorkspaceLocalState,
    physicalDeviceIDs: [UInt64: WorkspacePhysicalDeviceID] = [:],
    timeSeconds: Float = Float(ProcessInfo.processInfo.systemUptime)
  ) throws {
    let projection = try runtimeProjection(
      programInternalID: programInternalID, role: role, localState: localState,
      physicalDeviceIDs: physicalDeviceIDs,
      timeSeconds: timeSeconds)
    runtime.updateProgram(projection.configuration)
    runtime.updateProgramPreferences(projection.preferences)
  }
}
