// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgramRuntime
import LDTXTaskQueue
import MetalKit
import SwiftUI

public struct WorkspaceDocumentContent: View {
  let document: WorkspaceDocument
  let landscapeRuntime: ProgramRuntime?
  let portraitRuntime: ProgramRuntime?
  let metalView: MTKView?
  let captureSessionCoordinator: WorkspaceCaptureSessionCoordinator?
  let lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry?

  public init(
    document: WorkspaceDocument,
    landscapeRuntime: ProgramRuntime?, portraitRuntime: ProgramRuntime?,
    metalView: MTKView?, captureSessionCoordinator: WorkspaceCaptureSessionCoordinator?,
    lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry?
  ) {
    self.document = document
    self.landscapeRuntime = landscapeRuntime
    self.portraitRuntime = portraitRuntime
    self.metalView = metalView
    self.captureSessionCoordinator = captureSessionCoordinator
    self.lowFrequencyUpdateRegistry = lowFrequencyUpdateRegistry
  }

  public var body: some View {
    if let landscapeRuntime, let portraitRuntime, let metalView,
      let captureSessionCoordinator, let lowFrequencyUpdateRegistry
    {
      WorkspaceScene(
        document: document, landscapeRuntime: landscapeRuntime, portraitRuntime: portraitRuntime,
        metalView: metalView, captureSessionCoordinator: captureSessionCoordinator,
        lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry
      )
      .frame(minWidth: document.stateService.minimumWindowWidth, minHeight: 400)
      .focusedSceneValue(\.workspaceUndoDisabled, true)
    }
  }
}

private struct WorkspaceUndoDisabledKey: FocusedValueKey {
  typealias Value = Bool
}

extension FocusedValues {
  var workspaceUndoDisabled: Bool? {
    get { self[WorkspaceUndoDisabledKey.self] }
    set { self[WorkspaceUndoDisabledKey.self] = newValue }
  }
}

public struct WorkspaceCommands: Commands {
  @FocusedValue(\.workspaceUndoDisabled) private var isUndoDisabled

  public init() {}

  public var body: some Commands {
    if isUndoDisabled == true {
      CommandGroup(replacing: .undoRedo) {
        Button("Undo") {}
          .keyboardShortcut("z", modifiers: .command)
          .disabled(true)
        Button("Redo") {}
          .keyboardShortcut("z", modifiers: [.command, .shift])
          .disabled(true)
      }
    }
  }
}
