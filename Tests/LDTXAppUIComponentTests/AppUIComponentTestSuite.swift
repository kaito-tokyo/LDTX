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

  @Suite(.enabled(if: ProcessInfo.processInfo.environment["LDTX_UI_TEST_SHARD"] != "2"))
  struct Shard1 {}

  @Suite(.enabled(if: ProcessInfo.processInfo.environment["LDTX_UI_TEST_SHARD"] != "1"))
  struct Shard2 {}
}

@MainActor
enum UIComponentTestEnvironment {
  static let documentController = NSDocumentController()
}
