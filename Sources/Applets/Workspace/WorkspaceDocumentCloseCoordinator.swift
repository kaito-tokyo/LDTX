// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Keeps the event loop available to SwiftUI's asynchronous document save bridge.
@MainActor
final class WorkspaceDocumentCloseCoordinator: NSObject {
  private(set) static var saveGeneration = 0
  private(set) static var pendingSaves = 0
  private static var saveWaiters: [CheckedContinuation<Void, Never>] = []

  static func waitForSaves() async {
    guard pendingSaves > 0 else { return }
    await withCheckedContinuation { saveWaiters.append($0) }
  }
  static func performActivity(for window: NSWindow?, action: @escaping () -> Void) {
    guard let document = window?.windowController?.document as? NSDocument else {
      action()
      return
    }
    document.performActivity(withSynchronousWaiting: false) { completion in
      document.continueActivity(action)
      completion()
    }
  }

  static func save(_ document: NSDocument, saveAs: Bool = false) {
    saveGeneration += 1
    pendingSaves += 1
    document.performActivity(withSynchronousWaiting: false) { completion in
      // Returning from save does not finish its asynchronous file access. Keep
      // this activity until AppKit reports success, failure, or cancellation.
      let pending = PendingSave {
        pendingSaves -= 1
        completion()
        if pendingSaves == 0 {
          let waiters = saveWaiters
          saveWaiters.removeAll()
          for waiter in waiters { waiter.resume() }
        }
      }
      // The delegate/context must outlive a save panel and the background write.
      // NSDocument guarantees the didSave callback, which releases this retain.
      let context = Unmanaged.passRetained(pending).toOpaque()
      let selector = #selector(PendingSave.document(_:didSave:contextInfo:))
      document.continueActivity {
        if saveAs {
          document.runModalSavePanel(
            for: .saveAsOperation, delegate: pending, didSave: selector, contextInfo: context)
        } else {
          document.save(withDelegate: pending, didSave: selector, contextInfo: context)
        }
      }
    }
  }

  @MainActor
  private final class PendingSave: NSObject {
    let completion: () -> Void
    init(completion: @escaping () -> Void) { self.completion = completion }

    @objc func document(
      _ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?
    ) {
      guard let contextInfo else { return }
      let pending = Unmanaged<PendingSave>.fromOpaque(contextInfo).takeRetainedValue()
      pending.completion()
    }
  }

  private weak var button: NSButton?
  private weak var window: NSWindow?
  private weak var originalTarget: AnyObject?
  private var originalAction: Selector?
  private var pending = false
  private var generation = 0

  isolated deinit { detach() }

  func attach(to window: NSWindow?) {
    guard self.window !== window else { return }
    detach()
    guard let window, let button = window.standardWindowButton(.closeButton) else { return }
    self.window = window
    self.button = button
    originalTarget = button.target
    originalAction = button.action
    button.target = self
    button.action = #selector(close(_:))
  }

  func detach() {
    generation += 1
    pending = false
    // NSControl may already have zeroed its weak target during our deinit.
    if button?.target === self
      || (button?.target == nil && button?.action == #selector(close(_:)))
    {
      button?.target = originalTarget
      button?.action = originalAction
    }
    window = nil
    button = nil
    originalTarget = nil
    originalAction = nil
  }

  @objc private func close(_ sender: Any?) {
    guard !pending, let window, let action = originalAction else { return }
    pending = true
    let generation = generation
    Self.performActivity(for: window) { [self] in
      guard self.generation == generation, self.window === window else { return }
      defer { pending = false }
      NSApplication.shared.sendAction(action, to: originalTarget, from: sender)
    }
  }
}
