// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletController

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let termination = WorkspaceApplicationTermination()

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    termination.applicationShouldTerminate(sender)
  }
}
