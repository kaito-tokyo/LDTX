// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import LDTXProtos
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletUI
import LDTXWorkspaceAppletService
import LDTXWorkspaceBundleFormat
import SwiftUI

@MainActor
func saveWorkspaceDocument(
  _ document: WorkspaceDocument, to url: URL,
  operation: NSDocument.SaveOperationType = .saveAsOperation
) async throws {
  _ = document.testCoordinator
  let snapshot = try await document.snapshot(contentType: WorkspaceDocument.readableContentTypes[0])
  let writer = document.packageWriter
  let progress = ProgressManager(totalCount: 1)
  try await writer.write(
    snapshot: snapshot, to: url, previous: nil, progress: progress.subprogress(assigningCount: 1))
  document.adoptDocumentURL(url)
  await document.acceptPersistedWrite()
  document.testSavedWorkspace = document.workspace
}

@MainActor
func loadWorkspaceDocument(at url: URL) async throws -> WorkspaceDocument {
  let document = WorkspaceDocument()
  let progress = ProgressManager(totalCount: 1)
  let snapshot = try await WorkspaceDocument.Reader().read(
    from: url, progress: progress.subprogress(assigningCount: 1))
  try await document.apply(snapshot: snapshot, previous: nil)
  document.testSavedWorkspace = document.workspace
  return document
}

// Component tests supply their own window; DocumentGroup owns production windows.
@MainActor
private final class WorkspaceTestHost {
  var coordinator: WorkspaceViewControllerRepresentation.Coordinator?
  var controllers: [WorkspaceWindowController] = []
  var windows: [NSWindow] = []
  var saved: WorkspaceV4Bundle?
}

@MainActor
extension WorkspaceDocument {
  private var testHost: WorkspaceTestHost {
    if let host = objc_getAssociatedObject(self, &workspaceTestHostKey) as? WorkspaceTestHost {
      return host
    }
    let host = WorkspaceTestHost()
    objc_setAssociatedObject(self, &workspaceTestHostKey, host, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return host
  }
  var testSavedWorkspace: WorkspaceV4Bundle? {
    get { testHost.saved }
    set { testHost.saved = newValue }
  }
  // Test-only conveniences retain the same editing connection as a production Rep.
  var testCoordinator: WorkspaceViewControllerRepresentation.Coordinator {
    if let coordinator = testHost.coordinator { return coordinator }
    let coordinator = WorkspaceViewControllerRepresentation.Coordinator(document: self)
    testHost.coordinator = coordinator
    return coordinator
  }
  var controller: WorkspaceWindowController { testCoordinator.windowController }
  var stateService: WorkspaceStateService { controller.stateService }
  var appletData: WorkspaceAppletData { controller.appletData }
  var persistenceCoordinator: WorkspaceV4PersistenceCoordinator { controller.persistenceCoordinator }
  var workspace: WorkspaceV4Bundle { stateService.editingWorkspace }
  func shutdown() async { await testCoordinator.shutdown() }
  var hasTestModelChanges: Bool {
    testHost.saved.map { workspace != $0 }
      ?? (workspace.definition.displayName != "Untitled" || !workspace.definition.programs.isEmpty)
  }
  var windowControllers: [WorkspaceWindowController] { testHost.controllers }
  func makeWindowControllers() { if windowControllers.isEmpty { addWindowController(controller) } }
  func addWindowController(_ controller: WorkspaceWindowController) {
    if testHost.coordinator?.windowController !== controller {
      testHost.coordinator?.disconnect()
      testHost.coordinator = WorkspaceViewControllerRepresentation.Coordinator(
        document: self, windowController: controller)
    }
    testHost.controllers.append(controller)
    let window = WorkspaceTestWindow(content: controller.contentController, document: self)
    controller.window = window
    testHost.windows.append(window)
  }
  func removeWindowController(_ controller: WorkspaceWindowController) {
    testHost.controllers.removeAll { $0 === controller }
  }
  func close() {
    testHost.windows.forEach { $0.close() }
    let controllers = testHost.controllers
    testHost.controllers = []
    testHost.windows = []
    Task {
      for controller in controllers { await controller.shutdown() }
      await shutdown()
    }
  }
  func captureTestBaseline() { testHost.saved = workspace }
}

@MainActor private var workspaceTestHostKey: UInt8 = 0
