// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit

@MainActor
protocol WorkspaceSaveActionTarget: AnyObject {
  var documentForWorkspaceSave: NSDocument? { get }
}

/// Enter SwiftUI's standard termination review only after outstanding saves drain.
/// SwiftUI reviews documents before forwarding applicationShouldTerminate to the
/// application delegate, so the delegate cannot protect that earlier review.
@MainActor
public final class WorkspaceApplication: NSApplication {
  private let documentTermination = WorkspaceDocumentTermination()

  public override func sendAction(_ action: Selector, to target: Any?, from sender: Any?) -> Bool {
    if target == nil,
      action == #selector(NSDocument.save(_:)) || action == #selector(NSDocument.saveAs(_:)),
      let actions = self.target(forAction: action, to: nil, from: sender)
        as? any WorkspaceSaveActionTarget
    {
      // AppKit's dispatch does not necessarily use the public target lookup.
      // Supply its corrected result explicitly so the native menu reaches it.
      return super.sendAction(action, to: actions, from: sender)
    }
    return super.sendAction(action, to: target, from: sender)
  }

  public override func target(forAction action: Selector, to target: Any?, from sender: Any?)
    -> Any?
  {
    let resolved = super.target(forAction: action, to: target, from: sender)
    guard target == nil,
      action == #selector(NSDocument.save(_:)) || action == #selector(NSDocument.saveAs(_:)),
      let document = resolved as? NSDocument
    else { return resolved }
    // AppKit resolves document actions before consulting window.nextResponder.
    // Redirect only the matching Workspace; other document types keep AppKit's target.
    for window in [keyWindow, mainWindow].compactMap({ $0 }) {
      guard window.windowController?.document as? NSDocument === document else { continue }
      var responder = window.nextResponder
      var visited: Set<ObjectIdentifier> = []
      while let current = responder, visited.insert(ObjectIdentifier(current)).inserted {
        if let actions = current as? any WorkspaceSaveActionTarget,
          actions.documentForWorkspaceSave === document, current.responds(to: action)
        {
          return current
        }
        responder = current.nextResponder
      }
    }
    return resolved
  }

  public override func terminate(_ sender: Any?) {
    documentTermination.request { [weak self] in self?.terminateAfterSaving(sender) }
  }

  private func terminateAfterSaving(_ sender: Any?) {
    super.terminate(sender)
  }
}

@MainActor
final class WorkspaceDocumentTermination {
  private let documents: () -> [NSDocument]
  private var requestTask: Task<Void, Never>?

  init(documents: @escaping () -> [NSDocument] = { NSDocumentController.shared.documents }) {
    self.documents = documents
  }

  func request(proceed: @escaping @MainActor () -> Void) {
    guard requestTask == nil else { return }
    requestTask = Task { @MainActor [self] in
      while true {
        let current = documents()
        let generation = WorkspaceDocumentCloseCoordinator.saveGeneration
        await WorkspaceDocumentCloseCoordinator.waitForSaves()
        // Start every barrier before awaiting any one document. No activity is
        // held while entering the standard reviewer or another document's queue.
        await withCheckedContinuation { continuation in
          var remaining = current.count
          guard remaining > 0 else {
            continuation.resume()
            return
          }
          for document in current {
            document.performActivity(withSynchronousWaiting: false) { completion in
              completion()
              remaining -= 1
              if remaining == 0 { continuation.resume() }
            }
          }
        }
        // Editing and opening/closing windows remain responsive while waiting.
        // Include saves requested meanwhile and recheck the document inventory.
        if generation == WorkspaceDocumentCloseCoordinator.saveGeneration,
          WorkspaceDocumentCloseCoordinator.pendingSaves == 0,
          Set(current.map(ObjectIdentifier.init)) == Set(documents().map(ObjectIdentifier.init))
        {
          // Standard termination can run a nested event loop while the delegate
          // awaits another MainActor task. Leave both this task and the main
          // dispatch queue before entering it so that the reply task can run.
          let documentIDs = Set(current.map(ObjectIdentifier.init))
          RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
              guard let self else { return }
              self.requestTask = nil
              guard generation == WorkspaceDocumentCloseCoordinator.saveGeneration,
                WorkspaceDocumentCloseCoordinator.pendingSaves == 0,
                documentIDs == Set(self.documents().map(ObjectIdentifier.init))
              else {
                self.request(proceed: proceed)
                return
              }
              proceed()
            }
          }
          return
        }
      }
    }
  }
}
