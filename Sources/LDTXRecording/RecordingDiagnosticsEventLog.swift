// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum RecordingDiagnosticsEventKind: String, Codable, Sendable {
  case recordingStarted = "recording_started"
  case outputStarted = "output_started"
  case outputStopped = "output_stopped"
  case outputReconstructionRequested = "output_reconstruction_requested"
  case normalCompletion = "normal_completion"
  case abnormalStop = "abnormal_stop"
}

public struct RecordingDiagnosticsContext: Equatable, Sendable {
  public let launchID: UUID
  public let launchUptimeNanoseconds: UInt64

  public init(launchID: UUID, launchUptimeNanoseconds: UInt64) {
    self.launchID = launchID
    self.launchUptimeNanoseconds = launchUptimeNanoseconds
  }

  public func uptimeMilliseconds(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Int64 {
    Int64((now >= launchUptimeNanoseconds ? now - launchUptimeNanoseconds : 0) / 1_000_000)
  }
}

public struct RecordingDiagnosticsEvent: Codable, Equatable, Sendable {
  public let timestampUnixMilliseconds: Int64
  public let launchID: UUID
  public let uptimeMilliseconds: Int64
  public let kind: RecordingDiagnosticsEventKind

  public init(
    timestampUnixMilliseconds: Int64, launchID: UUID, uptimeMilliseconds: Int64,
    kind: RecordingDiagnosticsEventKind
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

@MainActor
public final class RecordingDiagnosticsEventLog {
  nonisolated public static let directoryName = "Diagnostics"
  nonisolated public static let fileName = "events.jsonl"

  private let context: RecordingDiagnosticsContext
  private let fileHandle: FileHandle
  private let encoder = JSONEncoder()
  private var isClosed = false

  public init(packageDirectory: URL, context: RecordingDiagnosticsContext) throws {
    self.context = context
    let directory = packageDirectory.appendingPathComponent(Self.directoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent(Self.fileName)
    guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    fileHandle = try FileHandle(forWritingTo: fileURL)
  }

  deinit { try? fileHandle.close() }

  public func append(
    _ kind: RecordingDiagnosticsEventKind, date: Date = Date(),
    uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) throws {
    guard !isClosed else { throw CocoaError(.fileWriteFileExists) }
    let event = RecordingDiagnosticsEvent(
      timestampUnixMilliseconds: Int64((date.timeIntervalSince1970 * 1_000).rounded()),
      launchID: context.launchID,
      uptimeMilliseconds: context.uptimeMilliseconds(now: uptimeNanoseconds),
      kind: kind
    )
    var data = try encoder.encode(event)
    data.append(0x0A)
    try fileHandle.write(contentsOf: data)
  }

  public func close() throws {
    guard !isClosed else { return }
    isClosed = true
    try fileHandle.close()
  }

}

public enum RecordingDiagnosticsEventLogReader {
  public static func readCompleteEvents(from packageDirectory: URL) throws
    -> [RecordingDiagnosticsEvent]
  {
    let fileURL = packageDirectory.appendingPathComponent(
      RecordingDiagnosticsEventLog.directoryName, isDirectory: true
    ).appendingPathComponent(RecordingDiagnosticsEventLog.fileName)
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    let data = try Data(contentsOf: fileURL)
    let decoder = JSONDecoder()
    var completeData = data
    if completeData.last != 0x0A,
      let lastNewline = completeData.lastIndex(of: 0x0A)
    {
      completeData = completeData.prefix(through: lastNewline)
    } else if completeData.last != 0x0A {
      return []
    }
    return try completeData.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast().map
    {
      try decoder.decode(RecordingDiagnosticsEvent.self, from: Data($0))
    }
  }
}
