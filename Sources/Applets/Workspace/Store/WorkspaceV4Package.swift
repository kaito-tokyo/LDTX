// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletModel

/// The two persisted Version 4 documents held as one Workspace state.
public struct WorkspaceV4Package: Equatable, Sendable {
  public var definition: WorkspaceV4DefinitionDocument
  public var preferences: WorkspaceV4PreferencesDocument

  public init(
    definition: WorkspaceV4DefinitionDocument,
    preferences: WorkspaceV4PreferencesDocument
  ) {
    self.definition = definition
    self.preferences = preferences
  }
}
