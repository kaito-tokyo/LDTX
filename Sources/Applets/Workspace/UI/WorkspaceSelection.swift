// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct WorkspaceSelectionOption<ID: Hashable>: Identifiable, Equatable {
  let id: ID
  let name: String
}

enum WorkspaceSelectionRules {
  static func canSubmit<ID: Hashable>(
    _ selection: ID?, availableIDs: [ID], isEditable: Bool, loadError: String?
  ) -> Bool {
    guard isEditable else { return false }
    guard let selection else { return true }
    return loadError == nil && availableIDs.contains(selection)
  }

  static func reconciled<ID: Hashable>(_ selection: ID?, availableIDs: [ID]) -> ID? {
    selection.flatMap { availableIDs.contains($0) ? $0 : nil }
  }

  static func displayName<ID: Hashable>(
    selection: ID?, options: [WorkspaceSelectionOption<ID>], loaded: Bool,
    emptyLabel: String = "Unassigned"
  ) -> String {
    guard let selection else { return emptyLabel }
    guard loaded else { return "Checking…" }
    return options.first { $0.id == selection }?.name ?? "Unavailable"
  }
}

struct WorkspaceSelectionError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
