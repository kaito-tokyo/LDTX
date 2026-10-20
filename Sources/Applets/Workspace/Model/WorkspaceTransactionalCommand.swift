// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum WorkspaceCommandOutcome: Sendable {
  case succeeded
  case failed(NSError)
  case rejected(NSError)
}

/// Logical resource operations. Payloads, admission, completion boundaries and
/// execution belong to the Coordinator; Preferences value exchange is separate.
public enum WorkspaceTransactionalCommand: CaseIterable, Hashable, Sendable {
  case reconstructRuntime
  case updateDeviceAssignment
  case switchProgram
  case startOutputSession
  case stopOutputSession
  case closeWorkspace

  public var isAllowedDuringOutput: Bool {
    switch self {
    case .switchProgram, .stopOutputSession: true
    case .reconstructRuntime, .updateDeviceAssignment, .startOutputSession, .closeWorkspace: false
    }
  }

  /// Required reconciliation for a failed or invalidated command. This does
  /// not select the state to revert, own retry data, or automatically retry.
  public var requiresConsistencyRepair: Bool {
    switch self {
    case .reconstructRuntime, .updateDeviceAssignment, .switchProgram: true
    case .startOutputSession, .stopOutputSession, .closeWorkspace: false
    }
  }
}

/// Pure presentation policy for the commands invalidated by a single Stall.
/// Every command still needs a rejection result and its required reconciliation,
/// including Stop and Close. Failures are aggregated after consistency repair
/// and Stall; no command has a notification priority or suppression exception.
public struct WorkspaceCommandFailureNotification: Equatable, Sendable {
  public enum Dialog: Equatable, Sendable {
    case commandError
    /// Tell the user stopping failed; do not report output as stopped.
    case stopFailed
    /// Include Force Quit guidance and possible loss of unsaved edits/recordings.
    /// This is guidance only, never authorization to force quit.
    case closeFailed
  }

  public let command: WorkspaceTransactionalCommand
  public let dialog: Dialog

  /// A single alert for the entire failed batch, including Stop and Close.
  public static func aggregatedError(_ notifications: [Self], causedBy cause: NSError) -> NSError? {
    let visible = notifications
    guard let first = visible.first else { return nil }
    if visible.count == 1 { return first.error(causedBy: cause) }
    let errors = visible.map { $0.error(causedBy: cause) }
    var suggestions: [String] = []
    for error in errors {
      if let suggestion = error.localizedRecoverySuggestion, !suggestions.contains(suggestion) {
        suggestions.append(suggestion)
      }
    }
    return NSError(
      domain: cause.domain, code: cause.code,
      userInfo: [
        NSLocalizedDescriptionKey: "Workspace operations could not be completed.",
        NSLocalizedFailureReasonErrorKey: errors.map(\.localizedDescription).joined(separator: "\n")
          + "\n\n"
          + [cause.localizedDescription, cause.localizedFailureReason]
          .compactMap { $0 }.joined(separator: "\n"),
        NSLocalizedRecoverySuggestionErrorKey: suggestions.joined(separator: "\n\n"),
        NSUnderlyingErrorKey: cause,
      ])
  }

  /// Preserves the actionable cause while giving the existing error alert the
  /// command-specific recovery guidance. No recovery action is performed here.
  public func error(causedBy cause: NSError) -> NSError {
    let suggestion: String
    let description: String
    switch command {
    case .stopOutputSession:
      description = "Output could not be stopped."
      suggestion = "Output may still be running. Check its status before taking further action."
    case .closeWorkspace:
      description = "The Workspace could not be closed."
      suggestion =
        "If you choose Force Quit from the Apple menu, unsaved edits and recordings may be lost."
    case .reconstructRuntime:
      description = "The saved Workspace could not be applied."
      suggestion = "Review the error and save the Workspace again to reapply your changes."
    case .updateDeviceAssignment:
      description = "The device assignment could not be applied."
      suggestion = "Review the device and its connection, then choose the assignment again."
    case .switchProgram:
      description = "The Program could not be switched."
      suggestion = "Review the error, then select the Program again."
    case .startOutputSession:
      description = "Output could not be started."
      suggestion = "Review the output settings and error, then start output again."
    }
    return NSError(
      domain: cause.domain, code: cause.code,
      userInfo: [
        NSLocalizedDescriptionKey: description,
        NSLocalizedFailureReasonErrorKey: [
          cause.localizedDescription, cause.localizedFailureReason,
        ]
        .compactMap { $0 }.joined(separator: "\n"),
        NSLocalizedRecoverySuggestionErrorKey: [cause.localizedRecoverySuggestion, suggestion]
          .compactMap { $0 }.joined(separator: "\n\n"),
        NSUnderlyingErrorKey: cause,
      ])
  }

  public static func stalledCommands(
    _ commands: [WorkspaceTransactionalCommand]
  ) -> [Self] {
    commands.map { command in
      let dialog: Dialog =
        switch command {
        case .stopOutputSession: .stopFailed
        case .closeWorkspace: .closeFailed
        default: .commandError
        }
      return Self(command: command, dialog: dialog)
    }
  }
}
