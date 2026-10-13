// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProtos
import LDTXWorkspaceBundleFormat
import Observation
import SwiftUI

public struct WorkspaceViewControllerRepresentation: NSViewControllerRepresentable {
  let document: WorkspaceDocument
  @Environment(\.undoManager) private var undoManager

  public init(document: WorkspaceDocument) { self.document = document }

  public func makeCoordinator() -> Coordinator { Coordinator(document: document) }

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
  public final class Coordinator: WorkspaceDocumentEditingConnection {
    private weak var document: WorkspaceDocument?
    let windowController: WorkspaceWindowController
    private weak var undoManager: UndoManager?
    private var lastObservedSnapshot: WorkspaceDocument.Writer.Snapshot
    private var editsTask: Task<Void, Never>?
    private var isDisconnected = false

    init(document: WorkspaceDocument, windowController: WorkspaceWindowController? = nil) {
      self.document = document
      let owner = windowController ?? WorkspaceWindowController(document: document)
      self.windowController = owner
      lastObservedSnapshot = .init(
        workspace: owner.stateService.editingWorkspace, modelURLs: owner.stateService.modelURLs)
      document.editingConnection = self
      owner.contentController.didAttachWindow = { [weak self] window in
        guard let self else { return }
        self.windowController.attachWindow(window)
        if self.undoManager == nil { self.setUndoManager(window?.undoManager) }
      }
      let state = owner.stateService
      let changes = Observations {
        WorkspaceDocument.Writer.Snapshot(workspace: state.editingWorkspace, modelURLs: state.modelURLs)
      }
      editsTask = Task { @MainActor [weak self] in
        for await _ in changes {
          guard let self, !Task.isCancelled else { return }
          self.recordEdits()
        }
      }
    }

    isolated deinit {
      editsTask?.cancel()
      let owner = windowController
      Task { await owner.shutdown() }
    }

    func setUndoManager(_ manager: UndoManager?) {
      recordEdits()
      undoManager = manager
    }

    private var currentSnapshot: WorkspaceDocument.Writer.Snapshot {
      let state = windowController.stateService
      return .init(workspace: state.editingWorkspace, modelURLs: state.modelURLs)
    }

    func recordEdits() {
      let current = currentSnapshot
      guard current != lastObservedSnapshot else { return }
      registerUndo(to: lastObservedSnapshot)
      lastObservedSnapshot = current
    }

    private func registerUndo(to snapshot: WorkspaceDocument.Writer.Snapshot) {
      undoManager?.registerUndo(withTarget: self) { owner in
        MainActor.assumeIsolated { owner.restoreEditingSnapshot(snapshot) }
      }
      undoManager?.setActionName(String(localized: "Edit Workspace"))
    }

    private func restoreEditingSnapshot(_ snapshot: WorkspaceDocument.Writer.Snapshot) {
      registerUndo(to: currentSnapshot)
      replaceEditingSnapshot(snapshot)
    }

    private func replaceEditingSnapshot(_ snapshot: WorkspaceDocument.Writer.Snapshot) {
      let state = windowController.stateService
      state.replaceEditingWorkspace(snapshot.workspace)
      state.modelURLs = snapshot.modelURLs
      lastObservedSnapshot = currentSnapshot
    }

    var canReloadDocument: Bool { !windowController.stateService.isOutputActive }

    func snapshotForSaving() -> WorkspaceDocument.Writer.Snapshot {
      recordEdits()
      return currentSnapshot
    }

    func documentDidRead(_ workspace: WorkspaceV4Bundle, previous: WorkspaceV4Bundle?) {
      if previous != nil { recordEdits() }
      let current = currentSnapshot
      var incoming = workspace
      if let previous {
        if current.workspace.definition != previous.definition {
          incoming.definition = current.workspace.definition
        }
        if current.workspace.preferences != previous.preferences {
          incoming.preferences = current.workspace.preferences
        }
        if current.workspace.outputSettings != previous.outputSettings {
          incoming.outputSettings = current.workspace.outputSettings
        }
      }
      let ids = Set(incoming.definition.visions.compactMap(\.internalID))
      let models = previous == nil ? [:] : current.modelURLs.filter { ids.contains($0.key) }
      replaceEditingSnapshot(.init(workspace: incoming, modelURLs: models))
      if let url = document?.fileURL { windowController.adoptDocumentURL(url) }
      updateRuntime()
    }

    func documentDidSave(_ receipt: WorkspaceDocument.WriteReceipt) {
      recordEdits()
      let state = windowController.stateService
      let original = receipt.original.workspace
      if state.workspaceDefinition == original.definition {
        state.workspaceDefinition = receipt.saved.definition
      }
      if state.workspacePreferences == original.preferences {
        state.workspacePreferences = receipt.saved.preferences
      }
      if state.workspaceOutputSettings == original.outputSettings {
        state.workspaceOutputSettings = receipt.saved.outputSettings
      }
      state.workspaceModels.merge(receipt.saved.models) { _, saved in saved }
      for wrapper in receipt.saved.definition.visions {
        guard case .ldtxSceneDetectorVision(let saved) = wrapper.vision,
          let index = state.workspaceDefinition.visions.firstIndex(where: {
            $0.internalID == saved.internalID
          }), case .ldtxSceneDetectorVision(var current) = state.workspaceDefinition.visions[index].vision,
          receipt.original.modelURLs.keys.contains(saved.internalID)
        else { continue }
        let originalVision = original.definition.visions.first { $0.internalID == saved.internalID }
        guard case .ldtxSceneDetectorVision(let old)? = originalVision?.vision,
          current.modelRevision == old.modelRevision || current.modelRevision == saved.modelRevision
        else { continue }
        if state.modelURLs[current.internalID] == receipt.original.modelURLs[current.internalID] {
          state.modelURLs.removeValue(forKey: current.internalID)
        }
        current.modelRevision = saved.modelRevision
        state.workspaceDefinition.visions[index].vision = .ldtxSceneDetectorVision(current)
      }
      lastObservedSnapshot = currentSnapshot
      updateRuntime()
    }

    func documentURLDidChange(_ url: URL) { windowController.adoptDocumentURL(url) }
    func documentDidFail(_ error: Error) { windowController.reportError(error) }

    private func updateRuntime() {
      windowController.confirmedContentsDidChange()
    }

    func disconnect() {
      guard !isDisconnected else { return }
      isDisconnected = true
      editsTask?.cancel()
      undoManager?.removeAllActions(withTarget: self)
      if document?.editingConnection === self { document?.editingConnection = nil }
    }

    func shutdown() async {
      disconnect()
      await windowController.shutdown()
      if let message = windowController.shutdownFailureMessage {
        NSApplication.shared.presentError(NSError(
          domain: "tokyo.kaito.ldtx.WorkspaceShutdown", code: 1,
          userInfo: [NSLocalizedDescriptionKey: message]))
      }
    }
  }
}
