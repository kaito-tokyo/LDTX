// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletModel
import OSLog
import UserNotifications

@MainActor
final class WorkspaceNotifications: NSObject, UNUserNotificationCenterDelegate {
  private let center = UNUserNotificationCenter.current()
  private let logger = Logger(subsystem: "tokyo.kaito.ldtx", category: "WorkspaceNotifications")
  private var authorizationTask: Task<Bool, Error>?

  func install() {
    center.delegate = self
  }

  func screenshotsDidSave(_ screenshots: [WorkspaceScreenshot]) {
    guard !screenshots.isEmpty else { return }
    Task {
      do {
        guard try await authorize() else { return }
        try await Task.detached(priority: .utility) {
          let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LDTX-Notification-\(UUID())", isDirectory: true)
          defer { try? FileManager.default.removeItem(at: directory) }
          let content = try Self.screenshotContent(screenshots, attachmentDirectory: directory)
          try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(
              identifier: "workspace.screenshots.\(UUID())", content: content, trigger: nil))
        }.value
      } catch {
        logger.error(
          "Screenshot notification failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  nonisolated static func screenshotContent(
    _ screenshots: [WorkspaceScreenshot], attachmentDirectory: URL
  ) throws -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    content.title = "Screenshots saved"
    if let capturedAt = screenshots.first?.capturedAt {
      content.body = capturedAt.formatted(date: .numeric, time: .standard)
    }
    // Keep the original files as the click targets, independently of attachment storage.
    content.userInfo = ["screenshotPaths": screenshots.map { $0.url.path }]
    if let landscape = screenshots.first(where: { $0.programCanvas == .landscape }) {
      content.title = "Landscape Program screenshot saved"
      try FileManager.default.createDirectory(
        at: attachmentDirectory, withIntermediateDirectories: true)
      let copy = attachmentDirectory.appendingPathComponent(landscape.url.lastPathComponent)
      // The notification system may move the attachment into its own storage.
      try FileManager.default.copyItem(at: landscape.url, to: copy)
      content.attachments = [
        try UNNotificationAttachment(
          identifier: "landscapeProgram", url: copy,
          options: [UNNotificationAttachmentOptionsThumbnailHiddenKey: false])
      ]
    }
    return content
  }

  private func authorize() async throws -> Bool {
    if let authorizationTask { return try await authorizationTask.value }
    let task = Task {
      let settings = await center.notificationSettings()
      switch settings.authorizationStatus {
      case .notDetermined: return try await center.requestAuthorization(options: [.alert])
      case .authorized, .provisional: return true
      default: return false
      }
    }
    authorizationTask = task
    defer { authorizationTask = nil }
    return try await task.value
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (Int) -> Void
  ) {
    // C++ interoperability imports this delegate's NS_OPTIONS parameter as Int.
    completionHandler(Int(UNNotificationPresentationOptions([.banner, .list]).rawValue))
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping @Sendable () -> Void
  ) {
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      let paths = response.notification.request.content.userInfo["screenshotPaths"] as? [String]
    else {
      completionHandler()
      return
    }
    Task { @MainActor in
      let urls = paths.map { URL(fileURLWithPath: $0) }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
      if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
      completionHandler()
    }
  }
}
