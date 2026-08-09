// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXRecording
import Testing

@Suite struct RecordingDiagnosticsEventLogTests {
  @MainActor @Test func writesAllowedEventFieldsAndIgnoresIncompleteTail() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let launchID = UUID()
    let log = try RecordingDiagnosticsEventLog(
      packageDirectory: directory,
      context: RecordingDiagnosticsContext(launchID: launchID, launchUptimeNanoseconds: 1_000)
    )
    try log.append(
      .recordingStarted, date: Date(timeIntervalSince1970: 10), uptimeNanoseconds: 2_001_000)
    try log.close()
    let fileURL =
      directory
      .appendingPathComponent(RecordingDiagnosticsEventLog.directoryName)
      .appendingPathComponent(RecordingDiagnosticsEventLog.fileName)
    let completeLine = try #require(
      String(decoding: Data(contentsOf: fileURL), as: UTF8.self).split(separator: "\n").first
    )
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(completeLine.utf8)) as? [String: Any]
    )
    #expect(Set(object.keys) == ["timestamp_unix_ms", "launch_id", "uptime_ms", "kind"])
    let handle = try FileHandle(forWritingTo: fileURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{incomplete".utf8))
    try handle.close()

    let events = try RecordingDiagnosticsEventLogReader.readCompleteEvents(from: directory)
    #expect(
      events == [
        RecordingDiagnosticsEvent(
          timestampUnixMilliseconds: 10_000,
          launchID: launchID,
          uptimeMilliseconds: 2,
          kind: .recordingStarted
        )
      ])
  }

  @MainActor @Test func roundTripsEveryAllowedLifecycleEventKind() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let log = try RecordingDiagnosticsEventLog(
      packageDirectory: directory,
      context: RecordingDiagnosticsContext(launchID: UUID(), launchUptimeNanoseconds: 0)
    )
    let kinds: [RecordingDiagnosticsEventKind] = [
      .recordingStarted,
      .outputStarted,
      .outputStopped,
      .outputReconstructionRequested,
      .normalCompletion,
      .abnormalStop,
    ]
    for kind in kinds { try log.append(kind, date: .distantPast, uptimeNanoseconds: 1) }
    try log.close()
    #expect(
      try RecordingDiagnosticsEventLogReader.readCompleteEvents(from: directory).map(\.kind)
        == kinds)
  }

  @Test func serializesConcurrentAppends() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let log = try RecordingDiagnosticsEventLog(
      packageDirectory: directory,
      context: RecordingDiagnosticsContext(launchID: UUID(), launchUptimeNanoseconds: 0)
    )

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<100 {
        group.addTask {
          try log.append(
            .outputReconstructionRequested,
            date: Date(timeIntervalSince1970: Double(index)),
            uptimeNanoseconds: UInt64(index))
        }
      }
      try await group.waitForAll()
    }
    try log.close()

    #expect(try RecordingDiagnosticsEventLogReader.readCompleteEvents(from: directory).count == 100)
  }

  @Test func rejectsMalformedCompleteLine() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let diagnostics = directory.appendingPathComponent(
      RecordingDiagnosticsEventLog.directoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
    let fileURL = diagnostics.appendingPathComponent(RecordingDiagnosticsEventLog.fileName)
    try Data("{malformed}\n".utf8).write(to: fileURL)

    #expect(throws: DecodingError.self) {
      _ = try RecordingDiagnosticsEventLogReader.readCompleteEvents(from: directory)
    }
  }
}
