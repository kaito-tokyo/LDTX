// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Observation
import SwiftUI

public protocol WorkspaceDispatcherProtocol: AnyObject, Observable {
  @MainActor func saveWorkspaceDefinition() async throws
  @MainActor func saveWorkspacePreferences() async throws
}

extension EnvironmentValues {
  @Entry public var workspaceDispatcher: (any WorkspaceDispatcherProtocol)? = nil
}
