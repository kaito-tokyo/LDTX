// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import LDTXAppletSupport
import LDTXProtos
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletInterface
import LDTXWorkspaceAppletService
@testable import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import SwiftProtobuf
import Testing

@MainActor
func saveWorkspaceDocument(
  _ document: WorkspaceDocument, to url: URL,
  operation: NSDocument.SaveOperationType = .saveAsOperation
) async throws {
  try await withCheckedThrowingContinuation {
    (continuation: CheckedContinuation<Void, Error>) in
    document.save(to: url, ofType: "tokyo.kaito.ldtx.workspace", for: operation) { error in
      if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
  }
}
