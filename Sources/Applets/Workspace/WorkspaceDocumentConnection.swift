// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import Observation

@MainActor
final class WorkspaceDocumentConnection {
  private weak var document: WorkspaceDocument?
  let runtimeCoordinator: WorkspaceRuntimeCoordinator
  private weak var undoManager: UndoManager?
  private var lastObservedSnapshot: WorkspaceV4Bundle
  private var editsTask: Task<Void, Never>?
  private var isDisconnected = false
  private var documentTask: Task<Void, Never>?
  private var readGeneration = 0
  private let closeCoordinator = WorkspaceDocumentCloseCoordinator()

  init(document: WorkspaceDocument, runtimeCoordinator: WorkspaceRuntimeCoordinator) {
    self.document = document
    self.runtimeCoordinator = runtimeCoordinator
    lastObservedSnapshot = runtimeCoordinator.stateService.editingWorkspace
    synchronizeDocument()
    runtimeCoordinator.pairedPreview.attachWindow = { [weak self] window in
      self?.attachWindow(window)
      guard let self else { return nil }
      return WorkspaceDocumentActions(
        stateService: self.runtimeCoordinator.stateService, window: window)
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
    closeCoordinator.detach()
    editsTask?.cancel()
    documentTask?.cancel()
    let owner = runtimeCoordinator
    Task { await owner.shutdown() }
  }

  func attachWindow(_ window: NSWindow?) {
    runtimeCoordinator.attachWindow(window)
    closeCoordinator.attach(to: window)
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
    closeCoordinator.detach()
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
  private weak var stateService: WorkspaceStateService?
  private weak var window: NSWindow?

  init(stateService: WorkspaceStateService, window: NSWindow? = nil) {
    self.stateService = stateService
    self.window = window
    super.init()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  private var canRevert: Bool {
    stateService.map { !$0.isClosed && !$0.isOutputActive } ?? false
  }

  @objc func saveDocument(_ sender: Any?) {
    guard let document = window?.windowController?.document as? NSDocument else {
      nextResponder?.tryToPerform(#selector(NSDocument.save(_:)), with: sender)
      return
    }
    WorkspaceDocumentCloseCoordinator.save(document)
  }

  @objc func saveDocumentAs(_ sender: Any?) {
    guard let document = window?.windowController?.document as? NSDocument else {
      nextResponder?.tryToPerform(#selector(NSDocument.saveAs(_:)), with: sender)
      return
    }
    WorkspaceDocumentCloseCoordinator.save(document, saveAs: true)
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
    if item.action == #selector(NSDocument.save(_:))
      || item.action == #selector(NSDocument.saveAs(_:))
    {
      guard let document = window?.windowController?.document as? NSDocument else { return false }
      return document.validateUserInterfaceItem(item)
    }
    if item.action == #selector(revertDocumentToSaved(_:))
      || item.action == #selector(browseDocumentVersions(_:))
    {
      return canRevert
    }
    return true
  }
}
