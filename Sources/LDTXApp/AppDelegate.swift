// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXSettingsApplet
import LDTXWorkspace
import LDTXWorkspaceApplet
import SwiftUI

@MainActor
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var terminationPending = false
  private lazy var applicationRouter = AppRouter()
  private lazy var applicationMainMenu = AppMainMenu(
    router: applicationRouter,
    showSettings: { [weak self] in self?.showSettings() })
  private var settings: SettingsApplet?
  private var settingsClosingObserver: NSObjectProtocol?

  override init() {
    super.init()
    settingsClosingObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let window = notification.object as? NSWindow else { return }
      MainActor.assumeIsolated {
        guard let self, self.settings?.window === window else { return }
        self.settings = nil
      }
    }
  }

  private func showSettings() {
    if settings == nil {
      settings = SettingsApplet.open()
    }
    settings?.showWindow(nil)
    settings?.window?.makeKeyAndOrderFront(nil)
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminationPending else { return .terminateLater }
    guard applicationRouter.isPrepared else { return .terminateNow }
    terminationPending = true
    DispatchQueue.main.async { [weak self] in
      self?.applicationRouter.terminate { allowed in
        self?.terminationPending = false
        sender.reply(toApplicationShouldTerminate: allowed)
      }
    }
    return .terminateLater
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  func applicationWillFinishLaunching(_ notification: Notification) {
    guard !LDTXRuntimeMode.isUnitTesting else { return }
    NSApp.mainMenu = applicationMainMenu
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    applicationRouter.launch()
  }
  func application(_ application: NSApplication, open urls: [URL]) {
    applicationRouter.open(urls: urls)
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    applicationRouter.handleReopen(hasVisibleWindows: flag)
    return true
  }
}
