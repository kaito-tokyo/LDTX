// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Enter SwiftUI's standard termination review only after outstanding saves drain.
/// SwiftUI reviews documents before forwarding applicationShouldTerminate to the
/// application delegate, so the delegate cannot protect that earlier review.
@MainActor
public final class WorkspaceApplication: NSApplication {
  private let documentTermination = WorkspaceDocumentTermination()

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

  func request(proceed: @escaping () -> Void) {
    guard requestTask == nil else { return }
    requestTask = Task { @MainActor in
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
          break
        }
      }
      requestTask = nil
      proceed()
    }
  }
}
