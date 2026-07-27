// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import SQLite3

public enum DiagnosticsProduct: String, CaseIterable, Sendable {
  case ldtx
  case tiny

  public var applicationSupportDirectoryName: String {
    switch self {
    case .ldtx: "LDTX"
    case .tiny: "LDTXTiny"
    }
  }
}

public struct DiagnosticsDatabaseLocation: Equatable, Sendable {
  public let product: DiagnosticsProduct
  public let bundleIdentifier: String
  public let applicationVersion: String
  public let databaseURL: URL

  public init(
    product: DiagnosticsProduct,
    bundleIdentifier: String,
    applicationVersion: String,
    applicationSupportDirectory: URL? = nil
  ) throws {
    let allowedFileNameCharacters = CharacterSet.alphanumerics.union(
      CharacterSet(charactersIn: ".-_"))
    guard !bundleIdentifier.isEmpty,
      bundleIdentifier.unicodeScalars.allSatisfy({ allowedFileNameCharacters.contains($0) })
    else {
      throw DiagnosticsDatabaseError.invalidBundleIdentifier(bundleIdentifier)
    }
    guard !applicationVersion.isEmpty,
      applicationVersion.unicodeScalars.allSatisfy({
        allowedFileNameCharacters.contains($0)
      })
    else {
      throw DiagnosticsDatabaseError.invalidApplicationVersion(applicationVersion)
    }
    let support =
      try applicationSupportDirectory
      ?? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false
      )
    self.product = product
    self.bundleIdentifier = bundleIdentifier
    self.applicationVersion = applicationVersion
    databaseURL =
      support
      .appendingPathComponent(product.applicationSupportDirectoryName, isDirectory: true)
      .appendingPathComponent("Diagnostics", isDirectory: true)
      .appendingPathComponent("load-\(bundleIdentifier)-v\(applicationVersion).sqlite3")
  }
}

public struct DiagnosticsLoadSample: Codable, Equatable, Sendable {
  public let sampledAtUnixMilliseconds: Int64
  public let launchID: UUID
  public let uptimeMilliseconds: Int64
  public let physicalFootprintBytes: Int64
  public let thermalState: Int

  public init(
    sampledAtUnixMilliseconds: Int64,
    launchID: UUID,
    uptimeMilliseconds: Int64,
    physicalFootprintBytes: Int64,
    thermalState: Int
  ) {
    self.sampledAtUnixMilliseconds = sampledAtUnixMilliseconds
    self.launchID = launchID
    self.uptimeMilliseconds = uptimeMilliseconds
    self.physicalFootprintBytes = physicalFootprintBytes
    self.thermalState = thermalState
  }

  enum CodingKeys: String, CodingKey {
    case sampledAtUnixMilliseconds = "sampled_at_unix_ms"
    case launchID = "launch_id"
    case uptimeMilliseconds = "uptime_ms"
    case physicalFootprintBytes = "physical_footprint_bytes"
    case thermalState = "thermal_state"
  }
}

public struct DiagnosticsSampleCursor: Codable, Equatable, Sendable {
  public let sampledAtUnixMilliseconds: Int64
  public let launchID: UUID
  public let uptimeMilliseconds: Int64

  public init(sample: DiagnosticsLoadSample) {
    sampledAtUnixMilliseconds = sample.sampledAtUnixMilliseconds
    launchID = sample.launchID
    uptimeMilliseconds = sample.uptimeMilliseconds
  }
}

public struct DiagnosticsSamplePage: Equatable, Sendable {
  public let samples: [DiagnosticsLoadSample]
  public let nextCursor: DiagnosticsSampleCursor?

  public init(samples: [DiagnosticsLoadSample], nextCursor: DiagnosticsSampleCursor?) {
    self.samples = samples
    self.nextCursor = nextCursor
  }
}

public enum DiagnosticsDatabaseError: Error, LocalizedError, Equatable, Sendable {
  case invalidApplicationVersion(String)
  case invalidBundleIdentifier(String)
  case databaseNotFound(URL)
  case databaseInUse(URL)
  case schemaMismatch(URL, String)
  case sqlite(URL, String)
  case invalidTimeRange

  public var errorDescription: String? {
    switch self {
    case .invalidApplicationVersion(let version):
      "Invalid application version: \(version)"
    case .invalidBundleIdentifier(let identifier):
      "Invalid application bundle identifier: \(identifier)"
    case .databaseNotFound(let url):
      "Diagnostics database does not exist: \(url.path)"
    case .databaseInUse(let url):
      "Diagnostics database is already owned by another application process: \(url.path)"
    case .schemaMismatch(let url, let detail):
      "Diagnostics database schema is invalid at \(url.path): \(detail)"
    case .sqlite(let url, let detail):
      "Diagnostics database failed at \(url.path): \(detail)"
    case .invalidTimeRange:
      "The diagnostics start time must be earlier than the end time."
    }
  }
}

public final class DiagnosticsDatabase {
  private static let createSchemaSQL = """
    CREATE TABLE load_samples (
      sampled_at_unix_ms INTEGER NOT NULL,
      launch_id BLOB NOT NULL,
      uptime_ms INTEGER NOT NULL,
      physical_footprint_bytes INTEGER NOT NULL,
      thermal_state INTEGER NOT NULL,
      PRIMARY KEY (launch_id, uptime_ms)
    ) WITHOUT ROWID;
    CREATE INDEX load_samples_by_time ON load_samples(sampled_at_unix_ms);
    """

  private let url: URL
  private var handle: OpaquePointer?
  private var writerLease: DiagnosticsDatabaseWriterLease?

  public init(location: DiagnosticsDatabaseLocation, createIfMissing: Bool) throws {
    url = location.databaseURL
    if createIfMissing {
      do {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
      } catch {
        throw DiagnosticsDatabaseError.sqlite(url, error.localizedDescription)
      }
      writerLease = try DiagnosticsDatabaseWriterLease(databaseURL: url)
    }
    let exists = FileManager.default.fileExists(atPath: url.path)
    guard exists || createIfMissing else {
      throw DiagnosticsDatabaseError.databaseNotFound(url)
    }
    let flags =
      createIfMissing
      ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
      : SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
      let message = Self.message(handle)
      sqlite3_close(handle)
      handle = nil
      throw DiagnosticsDatabaseError.sqlite(url, message)
    }
    do {
      if !exists {
        try execute("PRAGMA journal_mode=WAL;")
        try execute(Self.createSchemaSQL)
      }
      if createIfMissing { try execute("PRAGMA synchronous=NORMAL;") }
      try execute("PRAGMA busy_timeout=100;")
      try validateSchema()
    } catch let error as DiagnosticsDatabaseError {
      let isCorrupt = exists && Self.isCorruptDatabase(handle)
      close()
      if isCorrupt {
        throw DiagnosticsDatabaseError.schemaMismatch(url, error.localizedDescription)
      }
      throw error
    } catch {
      close()
      throw error
    }
  }

  deinit { close() }

  public func close() {
    if let handle {
      sqlite3_close(handle)
      self.handle = nil
    }
    writerLease = nil
  }

  public func insert(_ samples: [DiagnosticsLoadSample]) throws {
    guard !samples.isEmpty else { return }
    try execute("BEGIN IMMEDIATE;")
    do {
      var statement: OpaquePointer?
      let sql = """
        INSERT INTO load_samples (
          sampled_at_unix_ms, launch_id, uptime_ms,
          physical_footprint_bytes, thermal_state
        ) VALUES (?, ?, ?, ?, ?);
        """
      try prepare(sql, statement: &statement)
      defer { sqlite3_finalize(statement) }
      for sample in samples {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_int64(statement, 1, sample.sampledAtUnixMilliseconds)
        var uuid = sample.launchID.uuid
        _ = withUnsafeBytes(of: &uuid) { bytes in
          sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), Self.transient)
        }
        sqlite3_bind_int64(statement, 3, sample.uptimeMilliseconds)
        sqlite3_bind_int64(statement, 4, sample.physicalFootprintBytes)
        sqlite3_bind_int(statement, 5, Int32(sample.thermalState))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
      }
      try execute("COMMIT;")
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  public func forEachSample(
    from startUnixMilliseconds: Int64,
    to endUnixMilliseconds: Int64,
    _ body: (DiagnosticsLoadSample) throws -> Void
  ) throws {
    guard startUnixMilliseconds < endUnixMilliseconds else {
      throw DiagnosticsDatabaseError.invalidTimeRange
    }
    try withReadSnapshot {
      try querySamples(
        from: startUnixMilliseconds, to: endUnixMilliseconds, after: nil, limit: nil, body)
    }
  }

  public func samplePage(
    from startUnixMilliseconds: Int64,
    to endUnixMilliseconds: Int64,
    after cursor: DiagnosticsSampleCursor?,
    limit: Int
  ) throws -> DiagnosticsSamplePage {
    guard startUnixMilliseconds < endUnixMilliseconds else {
      throw DiagnosticsDatabaseError.invalidTimeRange
    }
    precondition(limit > 0)
    var samples: [DiagnosticsLoadSample] = []
    try withReadSnapshot {
      try querySamples(
        from: startUnixMilliseconds, to: endUnixMilliseconds, after: cursor, limit: limit + 1
      ) { samples.append($0) }
    }
    guard samples.count > limit else {
      return DiagnosticsSamplePage(samples: samples, nextCursor: nil)
    }
    samples.removeLast()
    return DiagnosticsSamplePage(
      samples: samples,
      nextCursor: samples.last.map(DiagnosticsSampleCursor.init(sample:))
    )
  }

  private func querySamples(
    from startUnixMilliseconds: Int64,
    to endUnixMilliseconds: Int64,
    after cursor: DiagnosticsSampleCursor?,
    limit: Int?,
    _ body: (DiagnosticsLoadSample) throws -> Void
  ) throws {
    var statement: OpaquePointer?
    let cursorPredicate =
      cursor == nil
      ? ""
      : """
      AND (
        sampled_at_unix_ms > ? OR
        (sampled_at_unix_ms = ? AND launch_id > ?) OR
        (sampled_at_unix_ms = ? AND launch_id = ? AND uptime_ms > ?)
      )
      """
    let limitClause = limit == nil ? "" : "LIMIT ?"
    try prepare(
      """
      SELECT sampled_at_unix_ms, launch_id, uptime_ms,
             physical_footprint_bytes, thermal_state
      FROM load_samples
      WHERE sampled_at_unix_ms >= ? AND sampled_at_unix_ms < ?
      \(cursorPredicate)
      ORDER BY sampled_at_unix_ms ASC, launch_id ASC, uptime_ms ASC
      \(limitClause)
      ;
      """,
      statement: &statement
    )
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, startUnixMilliseconds)
    sqlite3_bind_int64(statement, 2, endUnixMilliseconds)
    var bindingIndex: Int32 = 3
    if let cursor {
      var uuid = cursor.launchID.uuid
      sqlite3_bind_int64(statement, bindingIndex, cursor.sampledAtUnixMilliseconds)
      sqlite3_bind_int64(statement, bindingIndex + 1, cursor.sampledAtUnixMilliseconds)
      withUnsafeBytes(of: &uuid) { bytes in
        sqlite3_bind_blob(
          statement, bindingIndex + 2, bytes.baseAddress, Int32(bytes.count), Self.transient)
        sqlite3_bind_int64(statement, bindingIndex + 3, cursor.sampledAtUnixMilliseconds)
        sqlite3_bind_blob(
          statement, bindingIndex + 4, bytes.baseAddress, Int32(bytes.count), Self.transient)
      }
      sqlite3_bind_int64(statement, bindingIndex + 5, cursor.uptimeMilliseconds)
      bindingIndex += 6
    }
    if let limit { sqlite3_bind_int64(statement, bindingIndex, Int64(limit)) }
    var stepResult = sqlite3_step(statement)
    while stepResult == SQLITE_ROW {
      guard let blob = sqlite3_column_blob(statement, 1), sqlite3_column_bytes(statement, 1) == 16
      else {
        throw DiagnosticsDatabaseError.schemaMismatch(url, "launch_id is not a 16-byte UUID")
      }
      let uuid = UnsafeRawPointer(blob).loadUnaligned(as: uuid_t.self)
      try body(
        DiagnosticsLoadSample(
          sampledAtUnixMilliseconds: sqlite3_column_int64(statement, 0),
          launchID: UUID(uuid: uuid),
          uptimeMilliseconds: sqlite3_column_int64(statement, 2),
          physicalFootprintBytes: sqlite3_column_int64(statement, 3),
          thermalState: Int(sqlite3_column_int(statement, 4))
        ))
      stepResult = sqlite3_step(statement)
    }
    guard stepResult == SQLITE_DONE else { throw sqliteError() }
  }

  private func withReadSnapshot<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN;")
    do {
      let value = try body()
      try execute("COMMIT;")
      return value
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  private func validateSchema() throws {
    struct Column: Equatable {
      var name: String
      var type: String
      var notNull: Bool
      var primaryKeyPosition: Int
    }
    let expected = [
      Column(name: "sampled_at_unix_ms", type: "INTEGER", notNull: true, primaryKeyPosition: 0),
      Column(name: "launch_id", type: "BLOB", notNull: true, primaryKeyPosition: 1),
      Column(name: "uptime_ms", type: "INTEGER", notNull: true, primaryKeyPosition: 2),
      Column(
        name: "physical_footprint_bytes", type: "INTEGER", notNull: true, primaryKeyPosition: 0),
      Column(name: "thermal_state", type: "INTEGER", notNull: true, primaryKeyPosition: 0),
    ]
    var statement: OpaquePointer?
    try prepare("PRAGMA table_info(load_samples);", statement: &statement)
    var actual: [Column] = []
    var stepResult = sqlite3_step(statement)
    while stepResult == SQLITE_ROW {
      actual.append(
        Column(
          name: String(cString: sqlite3_column_text(statement, 1)),
          type: String(cString: sqlite3_column_text(statement, 2)).uppercased(),
          notNull: sqlite3_column_int(statement, 3) != 0,
          primaryKeyPosition: Int(sqlite3_column_int(statement, 5))
        ))
      stepResult = sqlite3_step(statement)
    }
    sqlite3_finalize(statement)
    guard stepResult == SQLITE_DONE else { throw sqliteError() }
    guard actual == expected else {
      throw DiagnosticsDatabaseError.schemaMismatch(url, "load_samples columns do not match")
    }
    statement = nil
    try prepare(
      "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = 'load_samples';",
      statement: &statement
    )
    stepResult = sqlite3_step(statement)
    guard stepResult == SQLITE_ROW else {
      sqlite3_finalize(statement)
      if stepResult != SQLITE_DONE { throw sqliteError() }
      throw DiagnosticsDatabaseError.schemaMismatch(url, "load_samples table is missing")
    }
    guard let schemaText = sqlite3_column_text(statement, 0),
      String(cString: schemaText).uppercased().contains("WITHOUT ROWID")
    else {
      sqlite3_finalize(statement)
      throw DiagnosticsDatabaseError.schemaMismatch(url, "load_samples must use WITHOUT ROWID")
    }
    sqlite3_finalize(statement)
    statement = nil
    try prepare("PRAGMA index_list(load_samples);", statement: &statement)
    var matchingIndexProperties: [(unique: Bool, origin: String, partial: Bool)] = []
    stepResult = sqlite3_step(statement)
    while stepResult == SQLITE_ROW {
      let name = String(cString: sqlite3_column_text(statement, 1))
      if name == "load_samples_by_time" {
        matchingIndexProperties.append(
          (
            unique: sqlite3_column_int(statement, 2) != 0,
            origin: String(cString: sqlite3_column_text(statement, 3)),
            partial: sqlite3_column_int(statement, 4) != 0
          ))
      }
      stepResult = sqlite3_step(statement)
    }
    sqlite3_finalize(statement)
    guard stepResult == SQLITE_DONE else { throw sqliteError() }
    guard matchingIndexProperties.count == 1,
      matchingIndexProperties[0].unique == false,
      matchingIndexProperties[0].origin == "c",
      matchingIndexProperties[0].partial == false
    else {
      throw DiagnosticsDatabaseError.schemaMismatch(
        url, "load_samples_by_time properties do not match")
    }
    statement = nil
    try prepare("PRAGMA index_info(load_samples_by_time);", statement: &statement)
    var indexColumns: [String] = []
    stepResult = sqlite3_step(statement)
    while stepResult == SQLITE_ROW {
      if let columnName = sqlite3_column_text(statement, 2) {
        indexColumns.append(String(cString: columnName))
      } else {
        // Expression indexes report a NULL column name. Treat that as a
        // structural mismatch instead of passing NULL to String(cString:).
        indexColumns.append("")
      }
      stepResult = sqlite3_step(statement)
    }
    sqlite3_finalize(statement)
    guard stepResult == SQLITE_DONE else { throw sqliteError() }
    guard indexColumns == ["sampled_at_unix_ms"] else {
      throw DiagnosticsDatabaseError.schemaMismatch(url, "load_samples_by_time does not match")
    }
    statement = nil
    try prepare(
      "SELECT sql FROM sqlite_schema WHERE type = 'index' AND name = 'load_samples_by_time';",
      statement: &statement
    )
    stepResult = sqlite3_step(statement)
    guard stepResult == SQLITE_ROW, let indexSQL = sqlite3_column_text(statement, 0) else {
      sqlite3_finalize(statement)
      if stepResult != SQLITE_DONE { throw sqliteError() }
      throw DiagnosticsDatabaseError.schemaMismatch(url, "load_samples_by_time is missing")
    }
    let normalizedIndexSQL = String(cString: indexSQL)
      .filter { !$0.isWhitespace && $0 != ";" }
      .uppercased()
    sqlite3_finalize(statement)
    guard
      normalizedIndexSQL
        == "CREATEINDEXLOAD_SAMPLES_BY_TIMEONLOAD_SAMPLES(SAMPLED_AT_UNIX_MS)"
    else {
      throw DiagnosticsDatabaseError.schemaMismatch(
        url, "load_samples_by_time definition does not match")
    }
  }

  private func execute(_ sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? Self.message(handle)
      sqlite3_free(errorMessage)
      throw DiagnosticsDatabaseError.sqlite(url, message)
    }
  }

  private func prepare(_ sql: String, statement: inout OpaquePointer?) throws {
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw sqliteError()
    }
  }

  private func sqliteError() -> DiagnosticsDatabaseError {
    DiagnosticsDatabaseError.sqlite(url, Self.message(handle))
  }

  private static func message(_ handle: OpaquePointer?) -> String {
    handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
  }

  private static func isCorruptDatabase(_ handle: OpaquePointer?) -> Bool {
    switch sqlite3_errcode(handle) {
    case SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_FORMAT: true
    default: false
    }
  }

  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

private final class DiagnosticsDatabaseWriterLease {
  private var descriptor: Int32

  init(databaseURL: URL) throws {
    let lockURL = databaseURL.appendingPathExtension("lock")
    descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw DiagnosticsDatabaseError.sqlite(databaseURL, String(cString: strerror(errno)))
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let lockError = errno
      Darwin.close(descriptor)
      descriptor = -1
      if lockError == EWOULDBLOCK {
        throw DiagnosticsDatabaseError.databaseInUse(databaseURL)
      }
      throw DiagnosticsDatabaseError.sqlite(databaseURL, String(cString: strerror(lockError)))
    }
  }

  deinit {
    guard descriptor >= 0 else { return }
    flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
  }
}
