// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

// Standalone process: a blocked SwiftUI bridge must not strand the test runner.
import AppKit
import Observation
import SwiftUI
import Synchronization
import UniformTypeIdentifiers

private let attempts = Mutex(0)

private func report(_ message: String) {
  FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

// LaunchServices does not propagate the child's exit status through `open -W`.
private func finish(_ status: Int32) -> Never {
  if let path = ProcessInfo.processInfo.environment["LDTX_SAVE_CLOSE_RESULT"] {
    try? String(status).write(toFile: path, atomically: true, encoding: .utf8)
  }
  exit(status)
}

@MainActor
@Observable
private final class SaveCloseDocument: Document {
  nonisolated static let readableContentTypes: [UTType] = [.plainText]
  var text = "latest"

  struct Reader: DocumentReader {
    @concurrent func read(from source: sending URL, progress: consuming Subprogress)
      async throws -> sending String
    {
      try String(contentsOf: source, encoding: .utf8)
    }
  }

  struct Writer: DocumentWriter {
    @concurrent func write(
      snapshot: sending String, to destination: sending URL, previous: sending String?,
      progress: consuming Subprogress
    ) async throws {
      report("writer started")
      try await Task.sleep(for: .milliseconds(300))
      let attempt = attempts.withLock {
        $0 += 1
        return $0
      }
      if CommandLine.arguments.contains("--failure")
        || CommandLine.arguments.contains("--quit-failure")
        || (CommandLine.arguments.contains("--retry") && attempt == 1)
      {
        throw CocoaError(.fileWriteNoPermission)
      }
      try snapshot.write(to: destination, atomically: true, encoding: .utf8)
      report("writer returned")
    }
  }

  nonisolated func reader(configuration: sending ReadConfiguration) -> sending Reader { Reader() }
  nonisolated func writer(configuration: sending WriteConfiguration) -> sending Writer { Writer() }
  func apply(snapshot: sending String, previous: sending String?) async throws { text = snapshot }
  func snapshot(contentType: UTType) async throws -> sending String { text }
}

@MainActor
private enum ProbeState {
  static var gate: WorkspaceDocumentCloseCoordinator?
  static var started = false
  static var handledPanel = false
  static var documents: [SaveCloseDocument] = []
  static var expectedFiles: [(URL, String)] = []
  static var terminationReviewed = false
  static var handledPanels: Set<ObjectIdentifier> = []
  static var quitRequested = false
  static var closeButtonCalls = 0
  static var closeForwarder: CloseProbeForwarder?
  static var saveForwarder: SaveProbeForwarder?
}

@MainActor
private final class SaveProbeForwarder: NSResponder, WorkspaceSaveActionTarget {
  weak var documentForWorkspaceSave: NSDocument?
  init(document: NSDocument) {
    documentForWorkspaceSave = document
    super.init()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  @objc func saveDocument(_ sender: Any?) {
    guard let documentForWorkspaceSave else { return }
    report("native Save reached the Workspace save target")
    WorkspaceDocumentCloseCoordinator.save(documentForWorkspaceSave)
  }
  @objc func saveDocumentAs(_ sender: Any?) {
    guard let documentForWorkspaceSave else { return }
    WorkspaceDocumentCloseCoordinator.save(documentForWorkspaceSave, saveAs: true)
  }
}

@MainActor
private func nativeMenuSave(_ window: NSWindow, keyboard: Bool, protected: Bool) {
  func findSave(_ menu: NSMenu) -> (NSMenu, Int)? {
    for (index, item) in menu.items.enumerated() {
      if item.action == #selector(NSDocument.save(_:)) { return (menu, index) }
      if let submenu = item.submenu, let result = findSave(submenu) { return result }
    }
    return nil
  }
  guard let main = NSApplication.shared.mainMenu, let (menu, index) = findSave(main) else {
    report("FAIL: native Save menu missing")
    finish(96)
  }
  let item = menu.items[index]
  let resolved = NSApplication.shared.target(forAction: item.action!, to: item.target, from: item)
  if protected, resolved as AnyObject? !== ProbeState.saveForwarder {
    report(
      "Save action=\(NSStringFromSelector(item.action!)); app=\(type(of: NSApplication.shared)); key=\(String(describing: NSApplication.shared.keyWindow)); expected=\(String(describing: ProbeState.saveForwarder)); resolved=\(String(describing: resolved)); responds=\(ProbeState.saveForwarder?.responds(to: item.action!) ?? false)"
    )
    report("FAIL: native Save bypassed the Workspace save target")
    finish(96)
  }
  if let document = window.windowController?.document as? NSDocument,
    NSApplication.shared.target(forAction: item.action!, to: document, from: item) as AnyObject?
      !== document
  {
    report("FAIL: explicit document Save target was redirected")
    finish(96)
  }
  if keyboard {
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)!
    guard main.performKeyEquivalent(with: event) else { finish(96) }
  } else {
    menu.performActionForItem(at: index)
  }
  if protected, WorkspaceDocumentCloseCoordinator.saveGeneration == 0 {
    report("FAIL: native Save dispatch bypassed the Workspace save target")
    finish(96)
  }
  report("native Save menu action returned")
}

/// Observe the button target without changing the production gate or its action.
@MainActor
private final class CloseProbeForwarder: NSObject {
  private weak var target: AnyObject?
  private let action: Selector

  init(button: NSButton) {
    target = button.target
    action = button.action!
    super.init()
    button.target = self
    button.action = #selector(closeButton(_:))
  }

  @objc private func closeButton(_ sender: Any?) {
    ProbeState.closeButtonCalls += 1
    report("native Close reached the close button target")
    NSApplication.shared.sendAction(action, to: target, from: sender)
  }
}

@MainActor
private func nativeMenuClose(_ window: NSWindow, keyboard: Bool) {
  @MainActor func findClose(_ menu: NSMenu) -> (NSMenu, Int)? {
    for (index, item) in menu.items.enumerated() {
      if item.keyEquivalent == "w", item.keyEquivalentModifierMask == .command {
        return (menu, index)
      }
      if let submenu = item.submenu, let result = findClose(submenu) { return result }
    }
    return nil
  }
  guard NSApplication.shared.keyWindow === window,
    let main = NSApplication.shared.mainMenu, let (menu, index) = findClose(main)
  else {
    report("FAIL: isolated key window/native Close menu missing")
    finish(96)
  }
  let item = menu.items[index]
  guard item.action == #selector(NSWindow.performClose(_:)), item.target == nil,
    NSApplication.shared.target(forAction: item.action!) as AnyObject? === window
  else {
    report("FAIL: unexpected native Close action/target")
    finish(96)
  }
  report("native Close action=performClose:, target=nil, resolved window verified")
  if keyboard {
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13
    )!
    guard main.performKeyEquivalent(with: event) else {
      report("FAIL: native Command-W key equivalent was not handled")
      finish(96)
    }
    report("native Command-W key equivalent handled")
  } else {
    menu.performActionForItem(at: index)
    report("native File > Close menu action returned")
  }
}

@MainActor
private final class ProbeDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    ProbeState.terminationReviewed = true
    report("standard termination delegate reached")
    if CommandLine.arguments.contains("--quit-cancel")
      || CommandLine.arguments.contains("--quit-failure")
    {
      return .terminateCancel
    }
    if CommandLine.arguments.contains("--async-reply") {
      Task { @MainActor in
        await Task.yield()
        report("MainActor shutdown task replied to standard Quit")
        sender.reply(toApplicationShouldTerminate: true)
      }
      return .terminateLater
    }
    return .terminateNow
  }
  func applicationWillTerminate(_ notification: Notification) {
    for (url, expected) in ProbeState.expectedFiles {
      guard (try? String(contentsOf: url, encoding: .utf8)) == expected else {
        report("FAIL: Quit lost confirmed content")
        finish(97)
      }
    }
    report("PASS: standard Quit; all document files verified")
  }
}

private struct WorkspaceSaveCloseProbe: App {
  init() {
    if CommandLine.arguments.contains("--menu-close")
      || CommandLine.arguments.contains("--key-close")
    {
      // A bundled DocumentGroup may initially show Open instead of a document.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        if NSDocumentController.shared.documents.isEmpty {
          _ = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
        }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
        report("FAIL: isolated application startup timed out")
        finish(98)
      }
    }
  }
  @NSApplicationDelegateAdaptor(ProbeDelegate.self) private var delegate
  var body: some Scene {
    DocumentGroup { (content: SaveCloseDocument) in
      Text("Isolated Workspace save/close regression").task {
        guard !ProbeState.started else { return }
        ProbeState.started = true
        try? await Task.sleep(for: .seconds(1))
        guard let document = NSDocumentController.shared.documents.first,
          let window = document.windowControllers.first?.window
        else {
          report("FAIL: document window missing")
          finish(98)
        }
        let url =
          ProcessInfo.processInfo.environment["LDTX_SAVE_CLOSE_DESTINATION"]
          .map { URL(fileURLWithPath: $0) }
          ?? FileManager.default.temporaryDirectory
          .appendingPathComponent("ldtx-save-close-\(UUID().uuidString).txt")
        do { try "baseline".write(to: url, atomically: true, encoding: .utf8) } catch {
          report("FAIL: fixture: \(error)")
          finish(98)
        }
        let unprotected = CommandLine.arguments.contains("--unprotected")
        let failure = CommandLine.arguments.contains("--failure")
        let quitCancel = CommandLine.arguments.contains("--quit-cancel")
        let quitFailure = CommandLine.arguments.contains("--quit-failure")
        let quit = CommandLine.arguments.contains("--quit") || quitCancel || quitFailure
        document.fileURL = url
        document.fileType = UTType.plainText.identifier
        document.updateChangeCount(.changeDone)
        if !unprotected {
          ProbeState.gate = WorkspaceDocumentCloseCoordinator()
          ProbeState.gate?.attach(to: window)
        }
        let menuClose = CommandLine.arguments.contains("--menu-close")
        let keyboardClose = CommandLine.arguments.contains("--key-close")
        if menuClose || keyboardClose {
          if !unprotected {
            let actions = SaveProbeForwarder(document: document)
            actions.nextResponder = window.nextResponder
            window.nextResponder = actions
            ProbeState.saveForwarder = actions
          }
          ProbeState.closeForwarder = CloseProbeForwarder(
            button: window.standardWindowButton(.closeButton)!)
          NSApplication.shared.activate()
          window.makeKeyAndOrderFront(nil)
          try? await Task.sleep(for: .milliseconds(200))
        }
        let save: @MainActor @Sendable () -> Void = {
          if menuClose || keyboardClose {
            nativeMenuSave(window, keyboard: keyboardClose, protected: !unprotected)
          } else if unprotected {
            document.save(nil)
          } else {
            WorkspaceDocumentCloseCoordinator.save(document)
          }
        }
        let cancelSaveAs = CommandLine.arguments.contains("--cancel-save-as")
        let retry = CommandLine.arguments.contains("--retry")
        report("save requested")
        if quitCancel {
          document.fileURL = nil
        } else if cancelSaveAs {
          WorkspaceDocumentCloseCoordinator.save(document, saveAs: true)
        } else {
          save()
        }
        ProbeState.expectedFiles = [(url, "latest")]
        if CommandLine.arguments.contains("--multiple") {
          let second = try! NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
          try? await Task.sleep(for: .milliseconds(100))
          report("second document ready; contents=\(ProbeState.documents.count)")
          let secondContent = ProbeState.documents.last!
          secondContent.text = "second latest"
          let secondURL = url.deletingPathExtension().appendingPathExtension("second.txt")
          try! "second baseline".write(to: secondURL, atomically: true, encoding: .utf8)
          second.fileURL = secondURL
          second.fileType = UTType.plainText.identifier
          second.updateChangeCount(.changeDone)
          ProbeState.expectedFiles.append((secondURL, "second latest"))
          WorkspaceDocumentCloseCoordinator.save(second)
        }
        if cancelSaveAs || retry || quitCancel || quitFailure {
          let dismiss = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
              guard !ProbeState.handledPanel || quitFailure,
                let panel = window.attachedSheet ?? NSApplication.shared.modalWindow
                  ?? NSApplication.shared.windows.first(where: { $0 !== window && $0.isVisible }),
                !ProbeState.handledPanels.contains(ObjectIdentifier(panel))
              else { return }
              ProbeState.handledPanels.insert(ObjectIdentifier(panel))
              ProbeState.handledPanel = !quitFailure || attempts.withLock { $0 > 0 }
              if cancelSaveAs, let savePanel = panel as? NSSavePanel {
                report("cancel Save As")
                savePanel.cancel(nil)
              } else if quitCancel {
                guard ProbeState.quitRequested, WorkspaceDocumentCloseCoordinator.pendingSaves == 0,
                  attempts.withLock({ $0 }) == 0
                else {
                  report("FAIL: cancelled a pre-Quit save instead of standard Quit review")
                  finish(96)
                }
                report(
                  "cancel standard Quit confirmation; Quit already requested, saves=0, writes=0")
                if let savePanel = panel as? NSSavePanel {
                  savePanel.cancel(nil)
                } else if let parent = panel.sheetParent {
                  parent.endSheet(panel, returnCode: .alertSecondButtonReturn)
                } else {
                  NSApplication.shared.stopModal(withCode: .alertSecondButtonReturn)
                  panel.orderOut(nil)
                }
              } else if retry || quitFailure {
                @MainActor func buttons(_ view: NSView) -> [NSButton] {
                  if let button = view as? NSButton { return [button] }
                  return view.subviews.flatMap(buttons)
                }
                report("acknowledge failure and retry")
                if let view = panel.contentView,
                  let button = buttons(view).first(where: {
                    $0.keyEquivalent == "\r" && $0.isEnabled
                  })
                {
                  button.performClick(nil)
                } else if let parent = panel.sheetParent {
                  parent.endSheet(panel, returnCode: .alertFirstButtonReturn)
                } else {
                  NSApplication.shared.stopModal(withCode: .alertFirstButtonReturn)
                  panel.orderOut(nil)
                }
                if retry {
                  content.text = "retried"
                  document.updateChangeCount(.changeDone)
                }
              } else {
                report("FAIL: Save As panel missing")
                finish(96)
              }
              if cancelSaveAs || retry {
                save()
                window.performClose(nil)
              }
            }
          }
          RunLoop.main.add(dismiss, forMode: .common)
          RunLoop.main.add(dismiss, forMode: .modalPanel)
        }
        if CommandLine.arguments.contains("--repeated") {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            report("second save requested")
            save()
          }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
          report("close requested")
          if !cancelSaveAs && !retry {
            if quit {
              ProbeState.quitRequested = true
              report("Quit requested")
              NSApplication.shared.terminate(nil)
            } else if menuClose || keyboardClose {
              nativeMenuClose(window, keyboard: keyboardClose)
            } else {
              window.performClose(nil)
            }
          }
        }
        let timer = Timer(timeInterval: quitFailure ? 4 : 2, repeats: false) { _ in
          MainActor.assumeIsolated {
            let saved = try? String(contentsOf: url, encoding: .utf8)
            let open = NSDocumentController.shared.documents.contains { $0 === document }
            let closeRouteVerified =
              !(menuClose || keyboardClose) || ProbeState.closeButtonCalls == 1
            let quitCancelVerified =
              !quitCancel
              || (ProbeState.quitRequested && WorkspaceDocumentCloseCoordinator.pendingSaves == 0
                && attempts.withLock { $0 } == 0 && window.attachedSheet == nil
                && NSApplication.shared.modalWindow == nil)
            let documentVerified =
              (failure || quitCancel || quitFailure)
              ? open && document.isDocumentEdited && content.text == "latest" && saved == "baseline"
                && (!(quitCancel || quitFailure)
                  || (ProbeState.handledPanel && !ProbeState.terminationReviewed))
                && (!quitFailure || attempts.withLock { $0 > 0 })
              : !open && saved == (retry ? "retried" : "latest")
                && (!cancelSaveAs || ProbeState.handledPanel)
            let success = documentVerified && closeRouteVerified && quitCancelVerified
            if !success {
              report(
                "state open=\(open) edited=\(document.isDocumentEdited) handled=\(ProbeState.handledPanel) reviewed=\(ProbeState.terminationReviewed) disk=\(saved ?? "missing")"
              )
            }
            report(
              success ? "PASS: responsive; document and disk verified" : "FAIL: document/disk state"
            )
            try? FileManager.default.removeItem(at: url)
            finish(success ? 0 : 97)
          }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        DispatchQueue.global().asyncAfter(deadline: .now() + 7) {
          report("FAIL: main event loop blocked")
          finish(99)
        }
      }
    } makeDocument: { _, _ in
      let document = SaveCloseDocument()
      ProbeState.documents.append(document)
      return document
    }
  }
}

@main
@MainActor
private enum ProbeMain {
  static func main() {
    if !CommandLine.arguments.contains("--unprotected") { _ = WorkspaceApplication.shared }
    WorkspaceSaveCloseProbe.main()
  }
}
