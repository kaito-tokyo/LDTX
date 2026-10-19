// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@MainActor
public protocol WorkspaceAppletDelegate: AnyObject, Sendable {
  func workspaceCoordinator(for document: WorkspaceDocument) -> WorkspaceAppletCoordinator
}

private struct WorkspaceAppletDelegateKey: EnvironmentKey {
  static let defaultValue: (any WorkspaceAppletDelegate)? = nil
}

extension EnvironmentValues {
  public var workspaceAppletDelegate: any WorkspaceAppletDelegate {
    get {
      guard let delegate = self[WorkspaceAppletDelegateKey.self] else {
        preconditionFailure(
          "WorkspaceAppletDelegate must be injected at the application entry point")
      }
      return delegate
    }
    set { self[WorkspaceAppletDelegateKey.self] = newValue }
  }
}
