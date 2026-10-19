// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@MainActor
public protocol WorkspaceAppletDelegate: AnyObject, Sendable {
  func workspaceCoordinator(for document: WorkspaceDocument) -> WorkspaceAppletCoordinator
}

extension EnvironmentValues {
  @Entry public var workspaceAppletDelegate: (any WorkspaceAppletDelegate)? = nil
}
