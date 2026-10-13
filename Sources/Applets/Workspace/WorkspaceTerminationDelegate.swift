// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import OSLog

/// The SwiftUI application's AppKit bridge for asynchronous Workspace shutdown only.
@MainActor
public final class WorkspaceTerminationDelegate: NSObject, NSApplicationDelegate {
  private let hasPendingShutdown: () -> Bool
  private let shutdown: () async -> [String]
  private let reply: (NSApplication, Bool) -> Void
  private let presentFailure: (NSApplication, Error) -> Void
  private var terminationTask: Task<Void, Never>?
  public var finishApplicationResources: (() async -> Void)?
  private static let logger = Logger(
    subsystem: "tokyo.kaito.ldtx", category: "WorkspaceTermination")

  public override convenience init() {
    self.init(
      hasPendingShutdown: { WorkspaceWindowController.hasPendingApplicationShutdown },
      shutdown: { await WorkspaceWindowController.shutdownForApplicationTermination() },
      reply: { application, shouldTerminate in
        application.reply(toApplicationShouldTerminate: shouldTerminate)
      },
      presentFailure: { application, error in _ = application.presentError(error) })
  }

  init(
    hasPendingShutdown: @escaping () -> Bool,
    shutdown: @escaping () async -> [String],
    reply: @escaping (NSApplication, Bool) -> Void,
    presentFailure: @escaping (NSApplication, Error) -> Void
  ) {
    self.hasPendingShutdown = hasPendingShutdown
    self.shutdown = shutdown
    self.reply = reply
    self.presentFailure = presentFailure
    super.init()
  }

  public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard terminationTask == nil else { return .terminateLater }
    guard hasPendingShutdown() || finishApplicationResources != nil else { return .terminateNow }
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
      if failures.isEmpty { await finishApplicationResources?() }
      reply(sender, failures.isEmpty)
      terminationTask = nil
    }
    return .terminateLater
  }
}
