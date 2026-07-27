// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDiagnostics
import Testing

@Suite struct EventTaskLoggerTests {
  @Test func queueLocationsAreDistinctAndVersioned() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try EventTaskLogLocation(
      product: .ldtx,
      bundleIdentifier: "tokyo.kaito.ldtx.LDTX.test",
      applicationVersion: "1.2.3",
      queueKind: .workspaceEvents,
      queueID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      applicationSupportDirectory: root
    )
    let second = try EventTaskLogLocation(
      product: .ldtx,
      bundleIdentifier: "tokyo.kaito.ldtx.LDTX.test",
      applicationVersion: "1.2.3",
      queueKind: .sessionTasks,
      queueID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      applicationSupportDirectory: root
    )

    #expect(first.fileURL != second.fileURL)
    #expect(first.fileURL.lastPathComponent.contains("workspace-events"))
    #expect(second.fileURL.lastPathComponent.contains("session-tasks"))
    #expect(first.fileURL.lastPathComponent.hasSuffix("-v1.2.3.jsonl"))
  }

  @Test func writesFixedFieldsAndIgnoresIncompleteTail() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let launchID = UUID()
    let location = try EventTaskLogLocation(
      product: .tiny,
      bundleIdentifier: "tokyo.kaito.ldtx.LDTXTiny.test",
      applicationVersion: "1.0",
      queueKind: .workspaceEvents,
      queueID: UUID(),
      applicationSupportDirectory: root
    )
    let logger = EventTaskLogger(
      location: location,
      launchID: launchID,
      launchUptimeNanoseconds: 1_000
    )
    await logger.append(
      .outputStartRequested,
      date: Date(timeIntervalSince1970: 10),
      uptimeNanoseconds: 2_001_000
    )
    await logger.close()

    let completeLine = try #require(
      String(decoding: Data(contentsOf: location.fileURL), as: UTF8.self)
        .split(separator: "\n").first
    )
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(completeLine.utf8)) as? [String: Any])
    #expect(Set(object.keys) == ["timestamp_unix_ms", "launch_id", "uptime_ms", "kind"])
    let handle = try FileHandle(forWritingTo: location.fileURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{incomplete".utf8))
    try handle.close()

    #expect(
      try EventTaskLogReader.readCompleteEvents(from: location.fileURL) == [
        EventTaskLogEvent(
          timestampUnixMilliseconds: 10_000,
          launchID: launchID,
          uptimeMilliseconds: 2,
          kind: .outputStartRequested
        )
      ])
  }

  @Test func initializationFailureLeavesLoggerDisabled() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let location = try EventTaskLogLocation(
      product: .ldtx,
      bundleIdentifier: "tokyo.kaito.ldtx.LDTX.test",
      applicationVersion: "1.0",
      queueKind: .workspaceResources,
      queueID: UUID(),
      applicationSupportDirectory: root
    )
    try FileManager.default.createDirectory(
      at: location.fileURL.deletingLastPathComponent().deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data().write(to: location.fileURL.deletingLastPathComponent())

    let logger = EventTaskLogger(
      location: location,
      launchID: UUID(),
      launchUptimeNanoseconds: 0
    )
    await logger.append(.outputStopRequested)
    await logger.close()
    #expect(!FileManager.default.fileExists(atPath: location.fileURL.path))
  }

  @Test func closingBeforeFirstEventPermanentlyDisablesLogger() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let location = try EventTaskLogLocation(
      product: .ldtx,
      bundleIdentifier: "tokyo.kaito.ldtx.LDTX.test",
      applicationVersion: "1.0",
      queueKind: .workspaceEvents,
      queueID: UUID(),
      applicationSupportDirectory: root
    )
    let logger = EventTaskLogger(
      location: location,
      launchID: UUID(),
      launchUptimeNanoseconds: 0
    )

    await logger.close()
    await logger.append(.outputStartRequested)

    #expect(!FileManager.default.fileExists(atPath: location.fileURL.path))
  }

  @Test func retentionKeepsNewestMatchingFilesOnly() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let diagnosticsDirectory = root.appendingPathComponent("Diagnostics", isDirectory: true)
    try FileManager.default.createDirectory(
      at: diagnosticsDirectory, withIntermediateDirectories: true)
    let bundleIdentifier = "tokyo.kaito.ldtx.LDTX.test"
    let matchingFiles = try (0..<4).map { index in
      let fileURL = diagnosticsDirectory.appendingPathComponent(
        "events-\(bundleIdentifier)-session-tasks-\(index)-v1.0.jsonl")
      try Data().write(to: fileURL)
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index))],
        ofItemAtPath: fileURL.path)
      return fileURL
    }
    let otherBundleFile = diagnosticsDirectory.appendingPathComponent(
      "events-tokyo.kaito.ldtx.LDTXTiny.test-session-tasks-0-v1.0.jsonl")
    try Data().write(to: otherBundleFile)

    try EventTaskLogRetention.prune(
      in: diagnosticsDirectory,
      bundleIdentifier: bundleIdentifier,
      retainingMostRecent: 2
    )

    #expect(!FileManager.default.fileExists(atPath: matchingFiles[0].path))
    #expect(!FileManager.default.fileExists(atPath: matchingFiles[1].path))
    #expect(FileManager.default.fileExists(atPath: matchingFiles[2].path))
    #expect(FileManager.default.fileExists(atPath: matchingFiles[3].path))
    #expect(FileManager.default.fileExists(atPath: otherBundleFile.path))
  }
}
