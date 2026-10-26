// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXCorelibs
import LDTXRecordPlayerApplet
import LDTXRecording
import LDTXWorkspaceAppletController
import Testing

@Suite(.serialized)
@MainActor
struct AppUIComponentTestSuite {
  init() { _ = UIComponentTestEnvironment.documentController }

}

@MainActor
enum UIComponentTestEnvironment {
  static let documentController = NSDocumentController()
}
