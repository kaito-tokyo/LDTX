// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import Observation

@MainActor
final class WorkspaceSceneConnection {
  private weak var document: WorkspaceDocument?
  let runtimeCoordinator: WorkspaceRuntimeCoordinator
  private weak var undoManager: UndoManager?
  private var lastObservedSnapshot: WorkspaceV4Bundle
  private var editsTask: Task<Void, Never>?
  private var isDisconnected = false
  private var documentTask: Task<Void, Never>?
  private var readGeneration = 0

  init(document: WorkspaceDocument, runtimeCoordinator: WorkspaceRuntimeCoordinator) {
    self.document = document
    self.runtimeCoordinator = runtimeCoordinator
    lastObservedSnapshot = runtimeCoordinator.stateService.editingWorkspace
    synchronizeDocument()
    runtimeCoordinator.viewState.didAttachWindow = { [weak self] window in
      self?.attachWindow(window)
    }
    let state = runtimeCoordinator.stateService
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
    let owner = runtimeCoordinator
    Task { await owner.shutdown() }
  }

  func attachWindow(_ window: NSWindow?) {
    runtimeCoordinator.attachWindow(window)
    if undoManager == nil { setUndoManager(window?.undoManager) }
  }

  func setUndoManager(_ manager: UndoManager?) {
    recordEdits()
    undoManager = manager
  }

  private var currentSnapshot: WorkspaceV4Bundle {
    runtimeCoordinator.stateService.editingWorkspace
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
    runtimeCoordinator.stateService.replaceEditingWorkspace(snapshot)
    lastObservedSnapshot = currentSnapshot
  }

  func synchronizeDocument() {
    guard let document, !isDisconnected else { return }
    if document.readGeneration != readGeneration, document.workspaceSnapshot != nil {
      document.adoptReadSnapshotForEditing()
      readGeneration = document.readGeneration
      lastObservedSnapshot = currentSnapshot
    }
    if let url = document.fileURL { runtimeCoordinator.adoptDocumentURL(url) }
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
    await runtimeCoordinator.shutdown()
    if let message = runtimeCoordinator.takeShutdownFailureForPresentation() {
      NSApplication.shared.presentError(
        NSError(
          domain: "tokyo.kaito.ldtx.WorkspaceShutdown", code: 1,
          userInfo: [NSLocalizedDescriptionKey: message]))
    }
  }
}

final class WorkspaceDocumentActions: NSResponder, NSUserInterfaceValidations {
  private weak var state: WorkspaceViewState?

  init(state: WorkspaceViewState) {
    self.state = state
    super.init()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  private var canRevert: Bool {
    state.map { !$0.isClosed && !$0.stateService.isOutputActive } ?? false
  }

  @objc func revertDocumentToSaved(_ sender: Any?) {
    guard canRevert else { return }
    nextResponder?.tryToPerform(#selector(revertDocumentToSaved(_:)), with: sender)
  }
  @objc func browseDocumentVersions(_ sender: Any?) {
    guard canRevert else { return }
    nextResponder?.tryToPerform(#selector(browseDocumentVersions(_:)), with: sender)
  }
  func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(revertDocumentToSaved(_:))
      || item.action == #selector(browseDocumentVersions(_:))
    {
      return canRevert
    }
    return true
  }
}
