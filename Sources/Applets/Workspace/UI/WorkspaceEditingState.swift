// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import Observation

@MainActor
@Observable
public final class WorkspaceEditingState {
  public init() {}

  public static func isInputValidationError(_ error: Error) -> Bool {
    error is WorkspaceSelectionError || error is RationalInputError
      || error is Rational32EncodingError || error is WorkspaceSaveValidationError
      || error is WorkspaceV4IntegrityError
  }

  private struct EditValidator {
    var hasChanges: () -> Bool
    var validate: () throws -> Void
    var submit: () throws -> Void
  }

  @ObservationIgnored private var contentEditValidators: [EditValidator] = []
  @ObservationIgnored private var inspectorEditValidators: [UUID: EditValidator] = [:]
  public private(set) var hasUnconfirmedChanges = false
  public func registerContentEditValidator(
    hasChanges: @escaping () -> Bool = { false },
    submit: @escaping () throws -> Void = {},
    _ validate: @escaping () throws -> Void
  ) {
    contentEditValidators.append(.init(hasChanges: hasChanges, validate: validate, submit: submit))
    refreshUnconfirmedChanges()
  }

  public func registerInspectorEditValidator(
    id: UUID, hasChanges: @escaping () -> Bool = { false },
    submit: @escaping () throws -> Void = {},
    _ validate: @escaping () throws -> Void
  ) {
    inspectorEditValidators[id] = .init(hasChanges: hasChanges, validate: validate, submit: submit)
    refreshUnconfirmedChanges()
  }

  public func removeInspectorEditValidator(id: UUID) {
    inspectorEditValidators.removeValue(forKey: id)
    refreshUnconfirmedChanges()
  }

  public func refreshUnconfirmedChanges() {
    hasUnconfirmedChanges =
      contentEditValidators.contains { $0.hasChanges() }
      || inspectorEditValidators.values.contains { $0.hasChanges() }
  }

  public func validateInspectorEdits() throws {
    for entry in contentEditValidators { try entry.validate() }
    for entry in inspectorEditValidators.values { try entry.validate() }
  }

  public func requireConfirmedEdits() throws {
    refreshUnconfirmedChanges()
    try validateInspectorEdits()
    guard !hasUnconfirmedChanges else {
      throw WorkspaceSelectionError(message: "Apply the pending edits before switching views.")
    }
  }

  // The Window is the only consumer. Validate every owner before invoking any writeback.
  public func submitPendingEdits(isOutputActive: Bool) {
    defer { refreshUnconfirmedChanges() }
    guard !isOutputActive else { return }
    let entries = contentEditValidators + Array(inspectorEditValidators.values)
    let pending = entries.filter { $0.hasChanges() }
    do {
      for entry in pending { try entry.validate() }
      for entry in pending { try entry.submit() }
    } catch { reportInputValidationError(error) }
  }

  @ObservationIgnored public var inputValidationErrorHandler: ((Error) -> Void)?

  public func reportInputValidationError(_ error: Error) {
    inputValidationErrorHandler?(error)
  }

}
