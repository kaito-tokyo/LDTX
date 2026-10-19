// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import Observation

@MainActor
final class WorkspaceDocumentConnection {
  private weak var document: WorkspaceDocument?
  let runtimeCoordinator: WorkspaceAppletCoordinator
  private var isDisconnected = false
  private var documentTask: Task<Void, Never>?
  private let closeCoordinator = WorkspaceDocumentCloseCoordinator()

  init(document: WorkspaceDocument, runtimeCoordinator: WorkspaceAppletCoordinator) {
    self.document = document
    self.runtimeCoordinator = runtimeCoordinator
    runtimeCoordinator.documentConnection = self
    synchronizeDocument()
    runtimeCoordinator.pairedPreview.attachWindow = { [weak self] window in
      self?.attachWindow(window)
      guard let self else { return nil }
      return WorkspaceDocumentActions(
        stateService: self.runtimeCoordinator.stateService, window: window)
    }
    let documentChanges = Observations { [weak document] in
      document?.fileURL
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
    documentTask?.cancel()
  }

  func attachWindow(_ window: NSWindow?) {
    runtimeCoordinator.attachWindow(window)
    closeCoordinator.attach(to: window)
  }

  func synchronizeDocument() {
    guard let document, !isDisconnected else { return }
    if let url = document.fileURL { runtimeCoordinator.adoptDocumentURL(url) }
  }

  func disconnect() {
    guard !isDisconnected else { return }
    isDisconnected = true
    closeCoordinator.detach()
    documentTask?.cancel()
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

final class WorkspaceDocumentActions: NSResponder, NSUserInterfaceValidations,
  WorkspaceSaveActionTarget
{
  private weak var stateService: WorkspaceDocument?
  private weak var window: NSWindow?

  init(stateService: WorkspaceDocument, window: NSWindow? = nil) {
    self.stateService = stateService
    self.window = window
    super.init()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  private var canRevert: Bool {
    stateService.map { !$0.isClosed && !$0.isOutputActive } ?? false
  }

  var documentForWorkspaceSave: NSDocument? {
    window?.windowController?.document as? NSDocument
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
