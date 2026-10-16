// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProgramRuntime
import LDTXTaskQueue
import LDTXWorkspaceAppletUI
import MetalKit
import SwiftUI

public struct WorkspaceScene: View {
  let document: WorkspaceDocument
  @Environment(\.undoManager) private var undoManager
  @State private var connection: WorkspaceSceneConnection?
  let landscapeRuntime: ProgramRuntime
  let portraitRuntime: ProgramRuntime
  let metalView: MTKView
  let captureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  let lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry

  public init(
    document: WorkspaceDocument, landscapeRuntime: ProgramRuntime, portraitRuntime: ProgramRuntime,
    metalView: MTKView, captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  ) {
    self.document = document
    self.landscapeRuntime = landscapeRuntime
    self.portraitRuntime = portraitRuntime
    self.metalView = metalView
    self.captureSessionCoordinator = captureSessionCoordinator
    self.lowFrequencyUpdateRegistry = lowFrequencyUpdateRegistry
  }

  public var body: some View {
    Group {
      if let connection {
        WorkspaceRootView(state: connection.runtimeCoordinator.viewState)
      }
    }
    .task {
      if connection == nil { connection = makeConnection() }
      connection?.setUndoManager(undoManager)
    }
    .onChange(of: undoManager) { _, manager in connection?.setUndoManager(manager) }
    .onDisappear {
      guard let connection else { return }
      connection.disconnect()
      Task { await connection.shutdown() }
    }
  }

  func makeConnection() -> WorkspaceSceneConnection {
    WorkspaceSceneConnection(
      document: document,
      runtimeCoordinator: WorkspaceRuntimeCoordinator(
        document: document, landscapeRuntime: landscapeRuntime, portraitRuntime: portraitRuntime,
        metalView: metalView, captureSessionCoordinator: captureSessionCoordinator,
        lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry))
  }
}

