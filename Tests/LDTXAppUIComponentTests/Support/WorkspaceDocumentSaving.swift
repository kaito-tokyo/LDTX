// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import LDTXProtos
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import SwiftUI

@MainActor
func saveWorkspaceDocument(
  _ document: WorkspaceDocument, to url: URL,
  operation: NSDocument.SaveOperationType = .saveAsOperation
) async throws {
  _ = document.testCoordinator
  let snapshot = try await document.snapshot(contentType: WorkspaceDocument.readableContentTypes[0])
  let writer = WorkspaceDocument.Writer()
  let progress = ProgressManager(totalCount: 1)
  try await writer.write(
    snapshot: snapshot, to: url, previous: nil, progress: progress.subprogress(assigningCount: 1))
  document.testSavedURL = url
  document.controller.adoptDocumentURL(url)
  document.testCoordinator.synchronizeDocument()
  await document.refreshTestPersistedWorkspace()
  document.testSavedWorkspace = document.workspace
}

@MainActor
func loadWorkspaceDocument(at url: URL) async throws -> WorkspaceDocument {
  let document = WorkspaceDocument()
  document.testSavedURL = url
  let progress = ProgressManager(totalCount: 1)
  let snapshot = try await WorkspaceDocument.Reader().read(
    from: url, progress: progress.subprogress(assigningCount: 1))
  try await document.apply(snapshot: snapshot, previous: nil)
  document.adoptReadSnapshotForEditing()
  document.testSavedWorkspace = document.workspace
  return document
}

// Component tests supply their own window; DocumentGroup owns production windows.
@MainActor
private final class WorkspaceTestHost {
  var savedURL: URL?
  var coordinator: WorkspaceDocumentConnection?
  var controllers: [WorkspaceRuntimeCoordinator] = []
  var windows: [NSWindow] = []
  var saved: WorkspaceV4Bundle?
}

@MainActor
extension WorkspaceDocument {
  // The test host owns IO destinations; a standalone Document has no SwiftUI URL configuration.
  var testSavedURL: URL? {
    get { testHost.savedURL }
    set { testHost.savedURL = newValue }
  }
  func refreshTestPersistedWorkspace() async {
    guard let url = testSavedURL else { return }
    await controller.refreshPersistedWorkspace(at: url) { self.testSavedURL == url }
  }
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
  // Test-only conveniences retain the production scene connection and runtime controller.
  var testCoordinator: WorkspaceDocumentConnection {
    if let coordinator = testHost.coordinator { return coordinator }
    let coordinator = WorkspaceDocumentConnection(document: self)
    testHost.coordinator = coordinator
    return coordinator
  }
  var controller: WorkspaceRuntimeCoordinator { testCoordinator.runtimeCoordinator }
  var appletData: WorkspaceAppletData { controller.appletData }
  var persistenceCoordinator: WorkspaceV4PersistenceCoordinator {
    controller.persistenceCoordinator
  }
  var workspace: WorkspaceV4Bundle { stateService.editingWorkspace }
  func shutdown() async { await testCoordinator.shutdown() }
  var hasTestModelChanges: Bool {
    testHost.saved.map { workspace != $0 }
      ?? (workspace.definition.displayName != "Untitled" || !workspace.definition.programs.isEmpty)
  }
  var windowControllers: [WorkspaceRuntimeCoordinator] { testHost.controllers }
  func makeWindowControllers() { if windowControllers.isEmpty { addWindowController(controller) } }
  func addWindowController(_ controller: WorkspaceRuntimeCoordinator) {
    if testHost.coordinator?.runtimeCoordinator !== controller {
      testHost.coordinator?.disconnect()
      testHost.coordinator = WorkspaceDocumentConnection(
        document: self, runtimeCoordinator: controller)
    }
    testHost.controllers.append(controller)
    let window = WorkspaceTestWindow(
      stateService: stateService, appletData: controller.appletData,
      deviceRegistry: controller.deviceRegistry, peakMeter: controller.peakMeter,
      pairedPreview: controller.pairedPreview, runtimeActions: { [weak controller] in controller },
      document: self)
    testCoordinator.attachWindow(window)
    controller.window = window
    testHost.windows.append(window)
  }
  func removeWindowController(_ controller: WorkspaceRuntimeCoordinator) {
    testHost.controllers.removeAll { $0 === controller }
  }
  func close() {
    for window in testHost.windows { window.close() }
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
