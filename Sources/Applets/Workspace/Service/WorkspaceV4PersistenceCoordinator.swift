// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXProgramRuntime
import LDTXProtos
import LDTXProtosMacOSExtra
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletStore
import LDTXWorkspaceBundleFormat
import Observation

/// Projects the document's model into window-scoped runtimes.
@MainActor
@Observable
public final class WorkspaceV4PersistenceCoordinator {
  private let workspaceSnapshot: () -> WorkspaceV4Bundle
  private let runtimeSnapshot: () -> WorkspaceV4Bundle
  private var adoptedRuntimeWorkspace: WorkspaceV4Bundle?
  private var outputPreferences: Ldtx_Workspace_V4_WorkspacePreferencesV4?
  private let replaceWorkspace: (WorkspaceV4Bundle) throws -> Void
  public private(set) var url: URL?
  var runtimeWorkspaceAdopted: ((WorkspaceV4Bundle) -> Void)?

  public init(
    workspaceSnapshot: @escaping () -> WorkspaceV4Bundle,
    replaceWorkspace: @escaping (WorkspaceV4Bundle) throws -> Void,
    url: URL? = nil,
    runtimeSnapshot: (() -> WorkspaceV4Bundle)? = nil
  ) {
    self.workspaceSnapshot = workspaceSnapshot
    self.runtimeSnapshot = runtimeSnapshot ?? workspaceSnapshot
    self.replaceWorkspace = replaceWorkspace
    self.url = url
  }

  func load(at url: URL) throws -> WorkspaceV4Bundle {
    let selectedReader = makeWorkspaceBundleReader(at: url)
    switch selectedReader {
    case .v4(let reader):
      let workspace = try reader.read()
      try workspace.definition.validateRichTextDocuments()
      return workspace
    case .failure:
      throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
    }
  }

  var workspace: WorkspaceV4Bundle { currentWorkspace }
  /// Canonical persisted content, without pending live preferences or output settings.
  public var persistedWorkspace: WorkspaceV4Bundle? { adoptedRuntimeWorkspace }
  public var hasPersistedWorkspace: Bool { adoptedRuntimeWorkspace != nil }
  var runtimeWorkspace: WorkspaceV4Bundle {
    let live = runtimeSnapshot()
    guard var adopted = adoptedRuntimeWorkspace else { return live }
    adopted.preferences =
      outputPreferences.map {
        Self.preferencesDuringOutput(live.preferences, membership: $0)
      } ?? live.preferences
    adopted.outputSettings = live.outputSettings
    return adopted
  }

  public func adoptRuntimeWorkspace(_ workspace: WorkspaceV4Bundle) throws {
    try Self.validateRuntimeWorkspace(workspace)
    adoptedRuntimeWorkspace = workspace
    runtimeWorkspaceAdopted?(workspace)
  }

  public static func validateRuntimeWorkspace(_ workspace: WorkspaceV4Bundle) throws {
    try workspace.definition.validateRichTextDocuments()
  }

  func setOutputActive(_ active: Bool) {
    if active {
      if outputPreferences == nil { outputPreferences = runtimeSnapshot().preferences }
    } else {
      outputPreferences = nil
    }
  }

  nonisolated static func preferencesDuringOutput(
    _ proposed: Ldtx_Workspace_V4_WorkspacePreferencesV4,
    membership: Ldtx_Workspace_V4_WorkspacePreferencesV4
  ) -> Ldtx_Workspace_V4_WorkspacePreferencesV4 {
    var result = proposed
    func preserveMembership(
      _ values: inout [Int64: Ldtx_Workspace_V4_ProgramPreferences],
      _ baseline: [Int64: Ldtx_Workspace_V4_ProgramPreferences]
    ) {
      for id in Set(values.keys).union(baseline.keys) {
        let expected = baseline[id]?.videoLayerInternalIds ?? []
        let proposed = values[id]?.videoLayerInternalIds ?? []
        if proposed.sorted() != expected.sorted() {
          values[id, default: .init()].videoLayerInternalIds = expected
        }
      }
    }
    preserveMembership(&result.landscapeProgramPreferences, membership.landscapeProgramPreferences)
    preserveMembership(&result.portraitProgramPreferences, membership.portraitProgramPreferences)
    return result
  }

  func replaceWorkspaceState(_ workspace: WorkspaceV4Bundle) throws {
    try replaceWorkspace(workspace)
  }

  private var currentWorkspace: WorkspaceV4Bundle { workspaceSnapshot() }

  public func open(at packageURL: URL) throws {
    try replaceWorkspace(load(at: packageURL))
    url = packageURL.standardizedFileURL
  }

  public func open(_ workspace: WorkspaceV4Bundle, at packageURL: URL) throws {
    try WorkspaceBundleValidatorV4.validate(workspace)
    try workspace.definition.validateRichTextDocuments()
    url = packageURL.standardizedFileURL
  }

  /// Synchronizes the formal document URL without changing content or save state.
  public func setDocumentURL(_ url: URL?) { self.url = url }

  /// Resolves the concrete capture hardware selected for the V4 input devices.
  /// Device assignments are app-local and never become Workspace data.
  func runtimeProjection(
    programInternalID: Int64,
    target: WorkspaceCanvasTarget,
    localState: WorkspaceLocalState,
    physicalDeviceIDs: [Int64: WorkspacePhysicalDeviceID] = [:],
    timeSeconds: Float = Float(ProcessInfo.processInfo.systemUptime)
  ) throws -> WorkspaceV4RuntimeProjection {
    let workspace = runtimeWorkspace
    let canvas = try WorkspaceProgramCanvasSnapshot(
      definition: workspace.definition, preferences: workspace.preferences,
      programInternalID: programInternalID, target: target)
    return try WorkspaceV4RenderGraph.runtimeProjection(
      definition: workspace.definition, canvas: canvas,
      physicalDeviceIDs: physicalDeviceIDs, timeSeconds: timeSeconds)
  }

  /// Installs one V4 Program directly into a shared preview or output runtime.
  func applyRuntime(
    _ runtime: ProgramRuntime,
    programInternalID: Int64,
    target: WorkspaceCanvasTarget,
    localState: WorkspaceLocalState,
    physicalDeviceIDs: [Int64: WorkspacePhysicalDeviceID] = [:],
    timeSeconds: Float = Float(ProcessInfo.processInfo.systemUptime)
  ) throws {
    let projection = try runtimeProjection(
      programInternalID: programInternalID, target: target, localState: localState,
      physicalDeviceIDs: physicalDeviceIDs,
      timeSeconds: timeSeconds)
    runtime.updateProgram(projection.configuration)
    runtime.updateProgramPreferences(projection.preferences)
  }
}
