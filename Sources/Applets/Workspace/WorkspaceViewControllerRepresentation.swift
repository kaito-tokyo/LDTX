// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProgramRuntime
import LDTXProtos
import LDTXTaskQueue
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import MetalKit
import Observation
import SwiftUI

public struct WorkspaceViewControllerRepresentation: NSViewControllerRepresentable {
  let document: WorkspaceDocument
  @Environment(\.undoManager) private var undoManager
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

  public func makeCoordinator() -> Coordinator {
    Coordinator(
      document: document,
      windowController: WorkspaceWindowController(
        document: document, landscapeRuntime: landscapeRuntime, portraitRuntime: portraitRuntime,
        metalView: metalView, captureSessionCoordinator: captureSessionCoordinator,
        lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry))
  }

  public func makeNSViewController(context: Context) -> WorkspaceViewController {
    context.coordinator.setUndoManager(undoManager)
    return context.coordinator.windowController.contentController
  }

  public func updateNSViewController(_ controller: WorkspaceViewController, context: Context) {
    context.coordinator.setUndoManager(undoManager ?? controller.view.window?.undoManager)
    context.coordinator.windowController.attachWindow(controller.view.window)
  }

  public static func dismantleNSViewController(
    _ controller: WorkspaceViewController, coordinator: Coordinator
  ) {
    coordinator.disconnect()
    Task { await coordinator.shutdown() }
  }

  @MainActor
  public final class Coordinator {
    private weak var document: WorkspaceDocument?
    let windowController: WorkspaceWindowController
    private weak var undoManager: UndoManager?
    private var lastObservedSnapshot: WorkspaceV4Bundle
    private var editsTask: Task<Void, Never>?
    private var isDisconnected = false
    private var documentTask: Task<Void, Never>?
    private var readGeneration = 0

    init(document: WorkspaceDocument, windowController: WorkspaceWindowController) {
      self.document = document
      let owner = windowController
      self.windowController = owner
      lastObservedSnapshot = owner.stateService.editingWorkspace
      synchronizeDocument()
      owner.contentController.didAttachWindow = { [weak self] window in
        guard let self else { return }
        self.windowController.attachWindow(window)
        if self.undoManager == nil { self.setUndoManager(window?.undoManager) }
      }
      let state = owner.stateService
      let changes = Observations {
        state.editingWorkspace
      }
      editsTask = Task { @MainActor [weak self] in
        for await _ in changes {
          guard let self, !Task.isCancelled else { return }
          self.recordEdits()
        }
      }
      let documentChanges = Observations { [weak document] in
        (document?.readGeneration, document?.fileURL)
      }
      documentTask = Task { @MainActor [weak self] in
        for await _ in documentChanges {
          guard let self, !Task.isCancelled else { return }
          self.synchronizeDocument()
        }
      }
    }

    isolated deinit {
      editsTask?.cancel()
      documentTask?.cancel()
      let owner = windowController
      Task { await owner.shutdown() }
    }

    func setUndoManager(_ manager: UndoManager?) {
      recordEdits()
      undoManager = manager
    }

    private var currentSnapshot: WorkspaceV4Bundle {
      let state = windowController.stateService
      return state.editingWorkspace
    }

    func recordEdits() {
      if document?.readGeneration != readGeneration { synchronizeDocument() }
      let current = currentSnapshot
      guard current != lastObservedSnapshot else { return }
      registerUndo(to: lastObservedSnapshot)
      lastObservedSnapshot = current
    }

    private func registerUndo(to snapshot: WorkspaceV4Bundle) {
      undoManager?.registerUndo(withTarget: self) { owner in
        MainActor.assumeIsolated { owner.restoreWorkspaceV4Bundle(snapshot) }
      }
      undoManager?.setActionName(String(localized: "Edit Workspace"))
    }

    private func restoreWorkspaceV4Bundle(_ snapshot: WorkspaceV4Bundle) {
      registerUndo(to: currentSnapshot)
      replaceWorkspaceV4Bundle(snapshot)
    }

    private func replaceWorkspaceV4Bundle(_ snapshot: WorkspaceV4Bundle) {
      let state = windowController.stateService
      state.replaceEditingWorkspace(snapshot)
      lastObservedSnapshot = currentSnapshot
    }

    func synchronizeDocument() {
      guard let document, !isDisconnected else { return }
      if document.readGeneration != readGeneration, document.workspaceSnapshot != nil {
        document.adoptReadSnapshotForEditing()
        readGeneration = document.readGeneration
        lastObservedSnapshot = currentSnapshot
      }
      if let url = document.fileURL { windowController.adoptDocumentURL(url) }
    }

    func disconnect() {
      guard !isDisconnected else { return }
      isDisconnected = true
      editsTask?.cancel()
      documentTask?.cancel()
      undoManager?.removeAllActions(withTarget: self)
    }

    func shutdown() async {
      disconnect()
      await windowController.shutdown()
      if let message = windowController.takeShutdownFailureForPresentation() {
        NSApplication.shared.presentError(
          NSError(
            domain: "tokyo.kaito.ldtx.WorkspaceShutdown", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]))
      }
    }
  }
}
