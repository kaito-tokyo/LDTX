// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLite3
import Testing

@testable import LDTXDiagnostics

@Suite struct DiagnosticsDatabaseTests {
  @Test func createsInsertsAndQueriesHalfOpenRange() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let location = try DiagnosticsDatabaseLocation(
      product: .ldtx,
      bundleIdentifier: "tokyo.kaito.ldtx.LDTX.test",
      applicationVersion: "1.2.3",
      applicationSupportDirectory: root
    )
    let database = try DiagnosticsDatabase(location: location, createIfMissing: true)
    let launchID = UUID()
    let samples = [1_000, 2_000, 3_000].map { timestamp in
      DiagnosticsLoadSample(
        sampledAtUnixMilliseconds: Int64(timestamp),
        launchID: launchID,
        uptimeMilliseconds: Int64(timestamp),
        physicalFootprintBytes: 2_000,
        thermalState: 0
      )
    }
    try database.insert(samples)
    var result: [DiagnosticsLoadSample] = []
    try database.forEachSample(from: 1_000, to: 3_000) { result.append($0) }
    #expect(result == Array(samples.prefix(2)))
    #expect(FileManager.default.fileExists(atPath: location.databaseURL.path))
  }

  @Test func versionCreatesIndependentFileAndRetainsOldFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try DiagnosticsDatabaseLocation(
      product: .tiny, bundleIdentifier: "tokyo.kaito.ldtx.LDTXTiny.test",
      applicationVersion: "1.0", applicationSupportDirectory: root)
    let second = try DiagnosticsDatabaseLocation(
      product: .tiny, bundleIdentifier: "tokyo.kaito.ldtx.LDTXTiny.test",
      applicationVersion: "1.1", applicationSupportDirectory: root)
    let firstDatabase = try DiagnosticsDatabase(location: first, createIfMissing: true)
    firstDatabase.close()
    let secondDatabase = try DiagnosticsDatabase(location: second, createIfMissing: true)
    secondDatabase.close()
    #expect(FileManager.default.fileExists(atPath: first.databaseURL.path))
    #expect(FileManager.default.fileExists(atPath: second.databaseURL.path))
  }

  @Test func bundleIdentifiersCreateIndependentVersionedFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let local = try DiagnosticsDatabaseLocation(
      product: .ldtx, bundleIdentifier: "tokyo.kaito.ldtx.LDTX.local",
      applicationVersion: "1.0", applicationSupportDirectory: root)
    let distribution = try DiagnosticsDatabaseLocation(
      product: .ldtx, bundleIdentifier: "tokyo.kaito.ldtx.LDTX",
      applicationVersion: "1.0", applicationSupportDirectory: root)

    #expect(local.databaseURL != distribution.databaseURL)
    #expect(local.databaseURL.lastPathComponent == "load-tokyo.kaito.ldtx.LDTX.local-v1.0.sqlite3")
    #expect(distribution.databaseURL.lastPathComponent == "load-tokyo.kaito.ldtx.LDTX-v1.0.sqlite3")
  }

  @Test func rejectsSecondWriterWithoutBlockingAndAllowsReaders() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let location = try DiagnosticsDatabaseLocation(
      product: .ldtx, bundleIdentifier: "tokyo.kaito.ldtx.LDTX.test",
      applicationVersion: "1.0", applicationSupportDirectory: root)
    let first = try DiagnosticsDatabase(location: location, createIfMissing: true)

    #expect(throws: DiagnosticsDatabaseError.databaseInUse(location.databaseURL)) {
      _ = try DiagnosticsDatabase(location: location, createIfMissing: true)
    }
    let reader = try DiagnosticsDatabase(location: location, createIfMissing: false)
    reader.close()
    first.close()
    let replacement = try DiagnosticsDatabase(location: location, createIfMissing: true)
    replacement.close()
  }

  @Test func readOnlyOpenDoesNotCreateMissingDatabase() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let location = try DiagnosticsDatabaseLocation(
      product: .ldtx, bundleIdentifier: "tokyo.kaito.ldtx.LDTX.test",
      applicationVersion: "1.0", applicationSupportDirectory: root)
    #expect(throws: DiagnosticsDatabaseError.self) {
      _ = try DiagnosticsDatabase(location: location, createIfMissing: false)
    }
  }

  @Test func rejectsExistingDatabaseWithMismatchedSchemaWithoutReplacingIt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let location = try DiagnosticsDatabaseLocation(
      product: .ldtx, bundleIdentifier: "tokyo.kaito.ldtx.LDTX.test",
      applicationVersion: "1.0", applicationSupportDirectory: root)
    try FileManager.default.createDirectory(
      at: location.databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var handle: OpaquePointer?
    #expect(sqlite3_open(location.databaseURL.path, &handle) == SQLITE_OK)
    #expect(
      sqlite3_exec(handle, "CREATE TABLE load_samples (unexpected INTEGER);", nil, nil, nil)
        == SQLITE_OK)
    sqlite3_close(handle)

    do {
      _ = try DiagnosticsDatabase(location: location, createIfMissing: true)
      Issue.record("Expected schema mismatch")
    } catch let error as DiagnosticsDatabaseError {
      guard case .schemaMismatch(let url, _) = error else {
        Issue.record("Unexpected diagnostics error: \(error)")
        return
      }
      #expect(url == location.databaseURL)
    }
    #expect(FileManager.default.fileExists(atPath: location.databaseURL.path))
  }

  @Test(arguments: [
    "CREATE UNIQUE INDEX load_samples_by_time ON load_samples(sampled_at_unix_ms);",
    "CREATE INDEX load_samples_by_time ON load_samples(sampled_at_unix_ms) WHERE thermal_state = 0;",
    "CREATE INDEX load_samples_by_time ON load_samples((sampled_at_unix_ms));",
  ])
  func rejectsNoncanonicalTimeIndex(_ indexSQL: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let location = try DiagnosticsDatabaseLocation(
      product: .ldtx,
      bundleIdentifier: "tokyo.kaito.ldtx.LDTX.test",
      applicationVersion: "1.0",
      applicationSupportDirectory: root
    )
    try FileManager.default.createDirectory(
      at: location.databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var handle: OpaquePointer?
    #expect(sqlite3_open(location.databaseURL.path, &handle) == SQLITE_OK)
    #expect(
      sqlite3_exec(
        handle,
        """
        CREATE TABLE load_samples (
          sampled_at_unix_ms INTEGER NOT NULL,
          launch_id BLOB NOT NULL,
          uptime_ms INTEGER NOT NULL,
          physical_footprint_bytes INTEGER NOT NULL,
          thermal_state INTEGER NOT NULL,
          PRIMARY KEY (launch_id, uptime_ms)
        ) WITHOUT ROWID;
        \(indexSQL)
        """,
        nil, nil, nil
      ) == SQLITE_OK)
    sqlite3_close(handle)

    do {
      _ = try DiagnosticsDatabase(location: location, createIfMissing: true)
      Issue.record("Expected schema mismatch")
    } catch let error as DiagnosticsDatabaseError {
      guard case .schemaMismatch = error else {
        Issue.record("Expected schema mismatch, got \(error)")
        return
      }
    }
  }

  @Test func classifiesUnreadableDatabaseAsSchemaMismatch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let location = try DiagnosticsDatabaseLocation(
      product: .ldtx, bundleIdentifier: "tokyo.kaito.ldtx.LDTX.test",
      applicationVersion: "1.0", applicationSupportDirectory: root)
    try FileManager.default.createDirectory(
      at: location.databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not a sqlite database".utf8).write(to: location.databaseURL)

    #expect(throws: DiagnosticsDatabaseError.self) {
      do {
        _ = try DiagnosticsDatabase(location: location, createIfMissing: true)
      } catch let error as DiagnosticsDatabaseError {
        guard case .schemaMismatch = error else {
          Issue.record("Expected schema mismatch, got \(error)")
          throw error
        }
        throw error
      }
    }
  }

  @Test func preservesTransientLockAsSQLiteError() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let location = try DiagnosticsDatabaseLocation(
      product: .ldtx, bundleIdentifier: "tokyo.kaito.ldtx.LDTX.test",
      applicationVersion: "1.0", applicationSupportDirectory: root)
    let database = try DiagnosticsDatabase(location: location, createIfMissing: true)
    database.close()

    var writer: OpaquePointer?
    #expect(sqlite3_open(location.databaseURL.path, &writer) == SQLITE_OK)
    defer {
      sqlite3_exec(writer, "ROLLBACK;", nil, nil, nil)
      sqlite3_close(writer)
    }
    #expect(sqlite3_exec(writer, "PRAGMA journal_mode=DELETE;", nil, nil, nil) == SQLITE_OK)
    #expect(sqlite3_exec(writer, "BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK)

    do {
      _ = try DiagnosticsDatabase(location: location, createIfMissing: false)
      Issue.record("Expected SQLite lock error")
    } catch let error as DiagnosticsDatabaseError {
      guard case .sqlite = error else {
        Issue.record("Expected SQLite error, got \(error)")
        return
      }
    }
  }

  @Test func buffersSixSamplesAsOneBatch() {
    var buffer = DiagnosticsSampleBuffer(capacity: 6)
    let launchID = UUID()
    for index in 0..<5 {
      #expect(buffer.append(sample(at: Int64(index), launchID: launchID)) == nil)
    }
    #expect(buffer.append(sample(at: 5, launchID: launchID))?.count == 6)
    #expect(buffer.drain().isEmpty)
  }

  @Test func createsIndependentSampleWithLaunchUptime() {
    let launchID = UUID()
    let sample = DiagnosticsSampleFactory(
      launchID: launchID,
      launchUptimeNanoseconds: 1_000_000_000
    ).makeSample(
      uptimeNanoseconds: 10_025_000_000,
      date: Date(timeIntervalSince1970: 123.456),
      thermalState: 2,
      physicalFootprintBytes: 4_096
    )

    #expect(sample.sampledAtUnixMilliseconds == 123_456)
    #expect(sample.launchID == launchID)
    #expect(sample.uptimeMilliseconds == 9_025)
    #expect(sample.physicalFootprintBytes == 4_096)
    #expect(sample.thermalState == 2)
  }

  @Test func pagesWithoutDuplicatingRows() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let location = try DiagnosticsDatabaseLocation(
      product: .ldtx, bundleIdentifier: "tokyo.kaito.ldtx.LDTX.test",
      applicationVersion: "1.0", applicationSupportDirectory: root)
    let database = try DiagnosticsDatabase(location: location, createIfMissing: true)
    let launchID = UUID()
    let samples = (0..<5).map { sample(at: Int64($0), launchID: launchID) }
    try database.insert(samples)

    let first = try database.samplePage(from: 0, to: 10, after: nil, limit: 2)
    let second = try database.samplePage(from: 0, to: 10, after: first.nextCursor, limit: 2)
    let third = try database.samplePage(from: 0, to: 10, after: second.nextCursor, limit: 2)

    #expect(first.samples + second.samples + third.samples == samples)
    #expect(first.nextCursor != nil)
    #expect(second.nextCursor != nil)
    #expect(third.nextCursor == nil)
  }

  private func sample(at timestamp: Int64, launchID: UUID) -> DiagnosticsLoadSample {
    DiagnosticsLoadSample(
      sampledAtUnixMilliseconds: timestamp,
      launchID: launchID,
      uptimeMilliseconds: timestamp,
      physicalFootprintBytes: 1,
      thermalState: 0
    )
  }
}
