// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Keeps the event loop available to SwiftUI's asynchronous document save bridge.
@MainActor
final class WorkspaceDocumentCloseCoordinator: NSObject, NSWindowDelegate {
  private let validateClose: @MainActor () throws -> Void
  private let closeWorkspace: (@MainActor () async -> Bool)?
  private let reportError: @MainActor (Error) -> Void
  private weak var originalDelegate: (any NSWindowDelegate)?

  init(
    validateClose: @escaping @MainActor () throws -> Void = {},
    closeWorkspace: (@MainActor () async -> Bool)? = nil,
    reportError: @escaping @MainActor (Error) -> Void = { _ in }
  ) {
    self.validateClose = validateClose
    self.closeWorkspace = closeWorkspace
    self.reportError = reportError
    super.init()
  }

  override func responds(to selector: Selector!) -> Bool {
    super.responds(to: selector) || (originalDelegate?.responds(to: selector) ?? false)
  }

  override func forwardingTarget(for selector: Selector!) -> Any? {
    originalDelegate?.responds(to: selector) == true
      ? originalDelegate : super.forwardingTarget(for: selector)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    requestClose(sender: sender)
    return false
  }

  func checkCloseAdmission() -> Bool {
    do {
      try validateClose()
      return true
    } catch {
      reportError(error)
      return false
    }
  }
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

  static func save(
    _ document: NSDocument, saveAs: Bool = false,
    onSuccess: @escaping @MainActor () -> Void = {}
  ) {
    saveGeneration += 1
    pendingSaves += 1
    document.performActivity(withSynchronousWaiting: false) { completion in
      // Returning from save does not finish its asynchronous file access. Keep
      // this activity until AppKit reports success, failure, or cancellation.
      let pending = PendingSave { didSave in
        pendingSaves -= 1
        completion()
        if pendingSaves == 0 {
          let waiters = saveWaiters
          saveWaiters.removeAll()
          for waiter in waiters { waiter.resume() }
        }
        if didSave { onSuccess() }
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
    let completion: (Bool) -> Void
    init(completion: @escaping (Bool) -> Void) { self.completion = completion }

    @objc func document(
      _ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?
    ) {
      guard let contextInfo else { return }
      let pending = Unmanaged<PendingSave>.fromOpaque(contextInfo).takeRetainedValue()
      pending.completion(didSave)
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
    if closeWorkspace != nil {
      originalDelegate = window.delegate
      window.delegate = self
    }
    button.target = self
    button.action = #selector(close(_:))
  }

  func detach() {
    generation += 1
    pending = false
    if window?.delegate === self { window?.delegate = originalDelegate }
    originalDelegate = nil
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
    requestClose(sender: sender)
  }

  private func requestClose(sender: Any?) {
    guard !pending, let window, let action = originalAction else { return }
    guard checkCloseAdmission() else { return }
    pending = true
    let generation = generation
    if let closeWorkspace {
      Task { @MainActor [self] in
        let document = window.windowController?.document as? NSDocument
        let allowed: Bool
        if let document { allowed = await Self.reviewClose(document) } else { allowed = true }
        guard self.generation == generation, self.window === window else { return }
        defer { pending = false }
        guard allowed, await closeWorkspace() else { return }
        if let document { document.close() } else { window.close() }
      }
      return
    }
    Self.performActivity(for: window) { [self] in
      guard self.generation == generation, self.window === window else { return }
      defer { pending = false }
      NSApplication.shared.sendAction(action, to: originalTarget, from: sender)
    }
  }

  static func reviewClose(_ document: NSDocument) async -> Bool {
    await withCheckedContinuation { continuation in
      document.performActivity(withSynchronousWaiting: false) { completion in
        completion()
        continuation.resume()
      }
    }
    return await withCheckedContinuation { continuation in
      let review = PendingClose(continuation)
      let context = Unmanaged.passRetained(review).toOpaque()
      document.canClose(
        withDelegate: review,
        shouldClose: #selector(PendingClose.document(_:shouldClose:contextInfo:)),
        contextInfo: context)
    }
  }

  @MainActor private final class PendingClose: NSObject {
    private let continuation: CheckedContinuation<Bool, Never>
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    @objc func document(
      _ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?
    ) {
      guard let contextInfo else { return }
      let review = Unmanaged<PendingClose>.fromOpaque(contextInfo).takeRetainedValue()
      review.continuation.resume(returning: shouldClose)
    }
  }
}
