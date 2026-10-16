// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgramRuntime
import LDTXTaskQueue
import LDTXWorkspaceAppletUI
import MetalKit
import SwiftUI

public struct WorkspaceDocumentContent: View {
  @Environment(\.undoManager) private var undoManager
  @State private var connection: WorkspaceDocumentConnection?
  let document: WorkspaceDocument
  let landscapeRuntime: ProgramRuntime?
  let portraitRuntime: ProgramRuntime?
  let metalView: MTKView?
  let captureSessionCoordinator: WorkspaceCaptureSessionCoordinator?

  public init(
    document: WorkspaceDocument,
    landscapeRuntime: ProgramRuntime?, portraitRuntime: ProgramRuntime?,
    metalView: MTKView?, captureSessionCoordinator: WorkspaceCaptureSessionCoordinator?
  ) {
    self.document = document
    self.landscapeRuntime = landscapeRuntime
    self.portraitRuntime = portraitRuntime
    self.metalView = metalView
    self.captureSessionCoordinator = captureSessionCoordinator
  }

  public var body: some View {
    if let landscapeRuntime, let portraitRuntime, let metalView,
      let captureSessionCoordinator
    {
      ZStack {
        if let connection { workspace(connection.runtimeCoordinator) }
      }
      .frame(minWidth: document.stateService.minimumWindowWidth, minHeight: 400)
      .focusedSceneValue(\.workspaceUndoDisabled, true)
      .task {
        if connection == nil {
          connection = WorkspaceDocumentConnection(
            document: document,
            runtimeCoordinator: WorkspaceRuntimeCoordinator(
              document: document, landscapeRuntime: landscapeRuntime,
              portraitRuntime: portraitRuntime,
              metalView: metalView, captureSessionCoordinator: captureSessionCoordinator))
        }
        connection?.setUndoManager(undoManager)
      }
      .onChange(of: undoManager) { _, manager in connection?.setUndoManager(manager) }
      .onDisappear {
        guard let connection else { return }
        connection.disconnect()
        Task { await connection.shutdown() }
      }
    }
  }

  private func workspace(_ runtime: WorkspaceRuntimeCoordinator) -> some View {
    let stateService = document.stateService
    let actions: () -> (any WorkspaceRuntimeActions)? = { [weak runtime] in
      guard !stateService.isClosed else { return nil }
      return runtime
    }
    let persistedWorkspace = { [weak runtime] in runtime?.windowRuntime.workspace }
    return WorkspaceLayout(
      stateService: stateService,
      sidebar: WorkspaceSidebar(
        stateService: stateService, deviceRegistry: runtime.deviceRegistry,
        appletData: runtime.appletData, document: document, runtimeActions: actions),
      content: WorkspaceContentPane(
        stateService: stateService, appletData: runtime.appletData, peakMeter: runtime.peakMeter,
        reportError: { [weak runtime] in runtime?.reportError($0) },
        pairedPreview: runtime.pairedPreview, runtimeActions: actions),
      inspector: WorkspaceInspectorContainer(
        deviceRegistry: runtime.deviceRegistry, stateService: stateService,
        appletData: runtime.appletData, document: document,
        variableStore: { [weak runtime] in runtime?.windowRuntime.variableStore },
        runtimeWorkspace: persistedWorkspace, runtimeActions: actions)
    )
    .environment(\.workspaceReportError, { [weak runtime] in runtime?.reportError($0) })
    .toolbar {
      WorkspaceToolbar(
        stateService: stateService, document: document, runtimeWorkspace: persistedWorkspace,
        runtimeActions: actions, runInference: { [weak runtime] in runtime?.runInference() })
    }
    .workspaceErrorAlert(stateService: stateService)
  }
}
