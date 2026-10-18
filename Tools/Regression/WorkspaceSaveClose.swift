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
    return .terminateNow
  }
  func applicationWillTerminate(_ notification: Notification) {
    for (url, expected) in ProbeState.expectedFiles {
      guard (try? String(contentsOf: url, encoding: .utf8)) == expected else {
        report("FAIL: Quit lost confirmed content")
        exit(97)
      }
    }
    report("PASS: standard Quit; all document files verified")
  }
}

private struct WorkspaceSaveCloseProbe: App {
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
          exit(98)
        }
        let url =
          ProcessInfo.processInfo.environment["LDTX_SAVE_CLOSE_DESTINATION"]
          .map { URL(fileURLWithPath: $0) }
          ?? FileManager.default.temporaryDirectory
          .appendingPathComponent("ldtx-save-close-\(UUID().uuidString).txt")
        do { try "baseline".write(to: url, atomically: true, encoding: .utf8) } catch {
          report("FAIL: fixture: \(error)")
          exit(98)
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
        let save: @MainActor @Sendable () -> Void = {
          if unprotected {
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
                report("cancel standard Quit confirmation")
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
                exit(96)
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
              report("Quit requested")
              NSApplication.shared.terminate(nil)
            } else {
              window.performClose(nil)
            }
          }
        }
        let timer = Timer(timeInterval: quitFailure ? 4 : 2, repeats: false) { _ in
          MainActor.assumeIsolated {
            let saved = try? String(contentsOf: url, encoding: .utf8)
            let open = NSDocumentController.shared.documents.contains { $0 === document }
            let success =
              (failure || quitCancel || quitFailure)
              ? open && document.isDocumentEdited && content.text == "latest" && saved == "baseline"
                && (!(quitCancel || quitFailure)
                  || (ProbeState.handledPanel && !ProbeState.terminationReviewed))
                && (!quitFailure || attempts.withLock { $0 > 0 })
              : !open && saved == (retry ? "retried" : "latest")
                && (!cancelSaveAs || ProbeState.handledPanel)
            if !success {
              report(
                "state open=\(open) edited=\(document.isDocumentEdited) handled=\(ProbeState.handledPanel) reviewed=\(ProbeState.terminationReviewed) disk=\(saved ?? "missing")"
              )
            }
            report(
              success ? "PASS: responsive; document and disk verified" : "FAIL: document/disk state"
            )
            try? FileManager.default.removeItem(at: url)
            exit(success ? 0 : 97)
          }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        DispatchQueue.global().asyncAfter(deadline: .now() + 7) {
          report("FAIL: main event loop blocked")
          exit(99)
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
