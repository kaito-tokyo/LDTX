// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit

@MainActor
final class LDTXDocumentController: NSDocumentController {
  override var defaultType: String? { "tokyo.kaito.ldtx.workspace" }
}
