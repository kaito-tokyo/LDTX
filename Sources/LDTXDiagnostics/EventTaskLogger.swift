// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import OSLog

private let eventTaskLoggerOSLog = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "event-task-diagnostics"
)

public enum EventTaskQueueKind: String, Codable, Sendable {
  case workspaceEvents = "workspace-events"
  case workspaceResources = "workspace-resources"
  case sessionTasks = "session-tasks"
}

public enum EventTaskLogEventKind: String, Codable, Sendable {
  case outputStartRequested = "output_start_requested"
  case outputStarted = "output_started"
  case outputStopRequested = "output_stop_requested"
  case outputStopped = "output_stopped"
  case outputReconstructionRequested = "output_reconstruction_requested"
  case outputRestartRequested = "output_restart_requested"
  case outputFailureHandlingStarted = "output_failure_handling_started"
  case outputFailureHandlingCompleted = "output_failure_handling_completed"
  case sessionTasksFinalized = "session_tasks_finalized"
}

public struct EventTaskLogEvent: Codable, Equatable, Sendable {
  public let timestampUnixMilliseconds: Int64
  public let launchID: UUID
  public let uptimeMilliseconds: Int64
  public let kind: EventTaskLogEventKind

  public init(
    timestampUnixMilliseconds: Int64,
    launchID: UUID,
    uptimeMilliseconds: Int64,
    kind: EventTaskLogEventKind
  ) {
    self.timestampUnixMilliseconds = timestampUnixMilliseconds
    self.launchID = launchID
    self.uptimeMilliseconds = uptimeMilliseconds
    self.kind = kind
  }

  enum CodingKeys: String, CodingKey {
    case timestampUnixMilliseconds = "timestamp_unix_ms"
    case launchID = "launch_id"
    case uptimeMilliseconds = "uptime_ms"
    case kind
  }
}

public struct EventTaskLogLocation: Equatable, Sendable {
  public let fileURL: URL
  public let bundleIdentifier: String
  public let queueKind: EventTaskQueueKind

  public init(
    product: DiagnosticsProduct,
    bundleIdentifier: String,
    applicationVersion: String,
    queueKind: EventTaskQueueKind,
    queueID: UUID,
    applicationSupportDirectory: URL? = nil
  ) throws {
    let databaseLocation = try DiagnosticsDatabaseLocation(
      product: product,
      bundleIdentifier: bundleIdentifier,
      applicationVersion: applicationVersion,
      applicationSupportDirectory: applicationSupportDirectory
    )
    self.bundleIdentifier = bundleIdentifier
    self.queueKind = queueKind
    fileURL = databaseLocation.databaseURL.deletingLastPathComponent().appendingPathComponent(
      "events-\(bundleIdentifier)-\(queueKind.rawValue)-\(queueID.uuidString.lowercased())-v\(applicationVersion).jsonl"
    )
  }
}

public enum EventTaskLogRetention {
  public static func prune(
    in diagnosticsDirectory: URL,
    bundleIdentifier: String,
    queueKind: EventTaskQueueKind? = nil,
    retainingMostRecent limit: Int
  ) throws {
    precondition(limit >= 0)
    guard FileManager.default.fileExists(atPath: diagnosticsDirectory.path) else { return }
    let prefix =
      "events-\(bundleIdentifier)-"
      + (queueKind.map { "\($0.rawValue)-" } ?? "")
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey, .contentModificationDateKey,
    ]
    let candidates = try FileManager.default.contentsOfDirectory(
      at: diagnosticsDirectory,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles]
    ).compactMap { fileURL -> (URL, Date)? in
      guard fileURL.lastPathComponent.hasPrefix(prefix),
        fileURL.pathExtension == "jsonl"
      else { return nil }
      let values = try fileURL.resourceValues(forKeys: keys)
      guard values.isRegularFile == true else { return nil }
      return (fileURL, values.contentModificationDate ?? .distantPast)
    }.sorted { lhs, rhs in
      if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
      return lhs.0.lastPathComponent > rhs.0.lastPathComponent
    }

    for (fileURL, _) in candidates.dropFirst(limit) {
      try FileManager.default.removeItem(at: fileURL)
    }
  }
}

public actor EventTaskLogger {
  private static let retainedSessionLogCount = 1_024
  public static let disabled = EventTaskLogger()

  private let location: EventTaskLogLocation?
  private let launchID: UUID?
  private let launchUptimeNanoseconds: UInt64
  private var fileHandle: FileHandle?
  private var isDisabled: Bool
  private let encoder = JSONEncoder()

  private init() {
    location = nil
    launchID = nil
    launchUptimeNanoseconds = 0
    fileHandle = nil
    isDisabled = true
  }

  public init(
    location: EventTaskLogLocation,
    launchID: UUID,
    launchUptimeNanoseconds: UInt64
  ) {
    self.location = location
    self.launchID = launchID
    self.launchUptimeNanoseconds = launchUptimeNanoseconds
    fileHandle = nil
    isDisabled = false
  }

  deinit { try? fileHandle?.close() }

  public func append(
    _ kind: EventTaskLogEventKind,
    date: Date = Date(),
    uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) {
    guard let launchID, let fileHandle = openFileIfNeeded() else { return }
    let elapsed =
      uptimeNanoseconds >= launchUptimeNanoseconds
      ? uptimeNanoseconds - launchUptimeNanoseconds : 0
    let event = EventTaskLogEvent(
      timestampUnixMilliseconds: Int64((date.timeIntervalSince1970 * 1_000).rounded()),
      launchID: launchID,
      uptimeMilliseconds: Int64(elapsed / 1_000_000),
      kind: kind
    )
    do {
      var data = try encoder.encode(event)
      data.append(0x0A)
      try fileHandle.write(contentsOf: data)
    } catch {
      eventTaskLoggerOSLog.error(
        "Event task diagnostics logger discarded an event and was disabled: \(error.localizedDescription, privacy: .public)"
      )
      try? fileHandle.close()
      self.fileHandle = nil
      isDisabled = true
      pruneSessionLogsIfNeeded()
    }
  }

  public func close() {
    isDisabled = true
    guard let fileHandle else {
      pruneSessionLogsIfNeeded()
      return
    }
    do {
      try fileHandle.close()
    } catch {
      eventTaskLoggerOSLog.error(
        "Event task diagnostics logger close failed: \(error.localizedDescription, privacy: .public)"
      )
    }
    self.fileHandle = nil
    pruneSessionLogsIfNeeded()
  }

  private func openFileIfNeeded() -> FileHandle? {
    if let fileHandle { return fileHandle }
    guard !isDisabled, let location else { return nil }
    do {
      try FileManager.default.createDirectory(
        at: location.fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if !FileManager.default.fileExists(atPath: location.fileURL.path) {
        guard FileManager.default.createFile(atPath: location.fileURL.path, contents: nil) else {
          throw CocoaError(.fileWriteUnknown)
        }
      }
      let handle = try FileHandle(forWritingTo: location.fileURL)
      try handle.seekToEnd()
      fileHandle = handle
      return handle
    } catch {
      isDisabled = true
      eventTaskLoggerOSLog.error(
        "Event task diagnostics logger was disabled: \(error.localizedDescription, privacy: .public)"
      )
      return nil
    }
  }

  private func pruneSessionLogsIfNeeded() {
    guard let location, location.queueKind == .sessionTasks else { return }
    do {
      try EventTaskLogRetention.prune(
        in: location.fileURL.deletingLastPathComponent(),
        bundleIdentifier: location.bundleIdentifier,
        queueKind: .sessionTasks,
        retainingMostRecent: Self.retainedSessionLogCount
      )
    } catch {
      eventTaskLoggerOSLog.error(
        "Old session task diagnostics logs could not be pruned: \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}

public enum EventTaskLogReader {
  public static func readCompleteEvents(from fileURL: URL) throws -> [EventTaskLogEvent] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    var data = try Data(contentsOf: fileURL)
    guard data.last == 0x0A else {
      guard let lastNewline = data.lastIndex(of: 0x0A) else { return [] }
      data = data.prefix(through: lastNewline)
      return try decodeCompleteLines(data)
    }
    return try decodeCompleteLines(data)
  }

  private static func decodeCompleteLines(_ data: Data) throws -> [EventTaskLogEvent] {
    let decoder = JSONDecoder()
    return try data.split(separator: 0x0A, omittingEmptySubsequences: true).map {
      try decoder.decode(EventTaskLogEvent.self, from: Data($0))
    }
  }
}
