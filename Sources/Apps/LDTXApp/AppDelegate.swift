// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var workspaceCoordinators: [UUID: WorkspaceAppletCoordinator] = [:]
  private weak var streamDeckWorkspace: WorkspaceAppletCoordinator?
  private lazy var streamDeck = WorkspaceStreamDeck { [weak self] in
    guard NSApp.modalWindow == nil,
      let coordinator = self?.streamDeckWorkspace,
      !coordinator.stateService.isClosed,
      let window = coordinator.window,
      window.attachedSheet == nil
    else { return nil }
    return coordinator
  }

  func activateStreamDeckWorkspace(_ coordinator: WorkspaceAppletCoordinator) {
    guard !coordinator.stateService.isClosed else { return }
    // Losing focus leaves ownership intact; only another Workspace takes over.
    streamDeckWorkspace = coordinator
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    streamDeck.start()
  }

  func applicationWillTerminate(_ notification: Notification) {
    streamDeck.stop()
  }

  private var shutdownFailures: [String] = []
  private lazy var termination = WorkspaceApplicationTermination(
    hasPendingShutdown: { [weak self] in
      guard let self else { return false }
      return !workspaceCoordinators.isEmpty || !shutdownFailures.isEmpty
    },
    shutdown: { [weak self] in
      guard let self else { return [] }
      // Keep closing coordinators alive until their existing cleanup has drained.
      let coordinators = Array(workspaceCoordinators.values)
      await withTaskGroup(of: String?.self) { group in
        for coordinator in coordinators {
          group.addTask {
            switch await coordinator.closeWorkspace() {
            case .succeeded: return nil
            case .failed(let error), .rejected(let error):
              return [
                error.localizedDescription, error.localizedFailureReason,
                error.localizedRecoverySuggestion,
              ]
              .compactMap { $0 }.joined(separator: "\n\n")
            }
          }
        }
        for await failure in group {
          if let failure { shutdownFailures.append(failure) }
        }
      }
      let failures = shutdownFailures
      shutdownFailures.removeAll()
      return failures
    })

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // SwiftUI's standard document review reaches this delegate only after saves
    // and cancellation have been resolved by WorkspaceApplication.
    termination.applicationShouldTerminate(sender)
  }

  func closeWorkspace(runtimeID: UUID) {
    guard let coordinator = workspaceCoordinators[runtimeID] else { return }
    Task { await coordinator.shutdown() }
  }

  private func workspaceDidShutdown(runtimeID: UUID) {
    guard let coordinator = workspaceCoordinators.removeValue(forKey: runtimeID) else { return }
    if streamDeckWorkspace === coordinator { streamDeckWorkspace = nil }
    updateRecordingDockBadge()
    guard let failure = coordinator.takeShutdownFailureForPresentation() else { return }
    if termination.isTerminationPending {
      shutdownFailures.append(failure)
    } else {
      NSApplication.shared.presentError(
        NSError(
          domain: "tokyo.kaito.ldtx.WorkspaceShutdown", code: 1,
          userInfo: [NSLocalizedDescriptionKey: failure]))
    }
  }

  private func updateRecordingDockBadge() {
    NSApplication.shared.dockTile.badgeLabel =
      workspaceCoordinators.values.contains { $0.stateService.isOutputActive } ? "REC" : nil
  }
}

extension AppDelegate: WorkspaceAppletDelegate {
  func workspaceCoordinator(for document: WorkspaceDocument) -> WorkspaceAppletCoordinator {
    if let coordinator = workspaceCoordinators[document.runtimeID] { return coordinator }
    precondition(
      !document.stateService.isClosed, "A closed Workspace cannot acquire another Coordinator")
    let id = document.runtimeID
    let coordinator = WorkspaceAppletCoordinator(document: document) { [weak self] in
      self?.workspaceDidShutdown(runtimeID: id)
    }
    coordinator.outputStateDidChange = { [weak self] in self?.updateRecordingDockBadge() }
    workspaceCoordinators[id] = coordinator
    return coordinator
  }
}
