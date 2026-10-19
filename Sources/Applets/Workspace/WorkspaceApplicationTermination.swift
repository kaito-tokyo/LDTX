// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import OSLog

/// Workspace shutdown policy used by the application's delegate.
@MainActor
public final class WorkspaceApplicationTermination: NSObject {
  private let hasPendingShutdown: @MainActor () -> Bool
  private let shutdown: @MainActor () async -> [String]
  private let reply: @MainActor (NSApplication, Bool) -> Void
  private let presentFailure: @MainActor (NSApplication, Error) -> Void
  private var terminationTask: Task<Void, Never>?
  public var isTerminationPending: Bool { terminationTask != nil }
  private static let logger = Logger(
    subsystem: "tokyo.kaito.ldtx", category: "WorkspaceTermination")

  public init(
    hasPendingShutdown: @escaping @MainActor () -> Bool,
    shutdown: @escaping @MainActor () async -> [String],
    reply: @escaping @MainActor (NSApplication, Bool) -> Void = {
      $0.reply(toApplicationShouldTerminate: $1)
    },
    presentFailure: @escaping @MainActor (NSApplication, Error) -> Void = {
      _ = $0.presentError($1)
    }
  ) {
    self.hasPendingShutdown = hasPendingShutdown
    self.shutdown = shutdown
    self.reply = reply
    self.presentFailure = presentFailure
    super.init()
  }

  public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard terminationTask == nil else { return .terminateLater }
    guard hasPendingShutdown() else { return .terminateNow }
    Self.logger.notice("workspace termination waiting for shutdown")
    terminationTask = Task { @MainActor in
      let failures = await shutdown()
      if !failures.isEmpty {
        presentFailure(
          sender,
          NSError(
            domain: "tokyo.kaito.ldtx.WorkspaceShutdown", code: 1,
            userInfo: [
              NSLocalizedDescriptionKey: String(localized: "Workspace shutdown failed."),
              NSLocalizedFailureReasonErrorKey: failures.joined(separator: "\n"),
            ]))
      }
      Self.logger.notice("workspace termination shutdown completed failures=\(failures.count)")
      reply(sender, failures.isEmpty)
      terminationTask = nil
    }
    return .terminateLater
  }
}
