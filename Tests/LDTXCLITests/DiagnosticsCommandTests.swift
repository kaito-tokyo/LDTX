// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDiagnostics
import Testing

@testable import LDTXHelper

@Suite struct DiagnosticsCommandTests {
  @Test func queriesTypedRowsInTheRequestedHalfOpenRange() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let location = try DiagnosticsDatabaseLocation(
      product: .tiny,
      bundleIdentifier: "tokyo.kaito.ldtx.LDTXTiny.test",
      applicationVersion: "9.8.7",
      applicationSupportDirectory: root
    )
    let database = try DiagnosticsDatabase(location: location, createIfMissing: true)
    let launchID = UUID()
    let samples = [1_000, 2_000, 3_000].map {
      DiagnosticsLoadSample(
        sampledAtUnixMilliseconds: Int64($0),
        launchID: launchID,
        uptimeMilliseconds: Int64($0),
        physicalFootprintBytes: 200,
        thermalState: 0
      )
    }
    try database.insert(samples)
    database.close()

    let outputURL = root.appendingPathComponent("output.json")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    let output = try FileHandle(forWritingTo: outputURL)
    try LDTXHelper.writeDiagnosticsSamples(
      start: "1970-01-01T00:00:01Z",
      end: "1970-01-01T00:00:03Z",
      product: .tiny,
      applicationVersion: "9.8.7",
      bundleIdentifier: "tokyo.kaito.ldtx.LDTXTiny.test",
      applicationSupportDirectory: root,
      output: output
    )
    try output.close()
    let result = try JSONDecoder().decode(
      [DiagnosticsLoadSample].self, from: Data(contentsOf: outputURL))
    #expect(result == Array(samples.prefix(2)))
  }

  @Test func rejectsInvalidAndReversedRFC3339RangesBeforeOpeningDatabase() {
    #expect(throws: Error.self) {
      try LDTXHelper.writeDiagnosticsSamples(
        start: "not-a-date",
        end: "2026-07-27T00:00:00Z",
        applicationVersion: "1.0",
        bundleIdentifier: "tokyo.kaito.ldtx.LDTX.test"
      )
    }
    #expect(throws: DiagnosticsDatabaseError.invalidTimeRange) {
      try LDTXHelper.writeDiagnosticsSamples(
        start: "2026-07-27T00:00:00Z",
        end: "2026-07-27T00:00:00Z",
        applicationVersion: "1.0",
        bundleIdentifier: "tokyo.kaito.ldtx.LDTX.test"
      )
    }
  }

  @Test func preservesSubmillisecondHalfOpenRangeBoundaries() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundleIdentifier = "tokyo.kaito.ldtx.LDTX.test"
    let location = try DiagnosticsDatabaseLocation(
      product: .ldtx,
      bundleIdentifier: bundleIdentifier,
      applicationVersion: "1.0",
      applicationSupportDirectory: root
    )
    let database = try DiagnosticsDatabase(location: location, createIfMissing: true)
    let launchID = UUID()
    let samples = [0, 1, 2].map {
      DiagnosticsLoadSample(
        sampledAtUnixMilliseconds: Int64($0),
        launchID: launchID,
        uptimeMilliseconds: Int64($0),
        physicalFootprintBytes: 200,
        thermalState: 0
      )
    }
    try database.insert(samples)
    database.close()

    let page = try LDTXHelper.queryDiagnosticsSamplePage(
      start: "1970-01-01T00:00:00.0004Z",
      end: "1970-01-01T00:00:00.0014Z",
      product: .ldtx,
      applicationVersion: "1.0",
      bundleIdentifier: bundleIdentifier,
      applicationSupportDirectory: root,
      limit: 10
    )

    #expect(page.samples == [samples[1]])
  }

  @Test func submillisecondRangeBetweenStoredTicksReturnsEmptyResults() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundleIdentifier = "tokyo.kaito.ldtx.LDTX.test"
    let location = try DiagnosticsDatabaseLocation(
      product: .ldtx,
      bundleIdentifier: bundleIdentifier,
      applicationVersion: "1.0",
      applicationSupportDirectory: root
    )
    try DiagnosticsDatabase(location: location, createIfMissing: true).close()

    let outputURL = root.appendingPathComponent("output.json")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    let output = try FileHandle(forWritingTo: outputURL)
    try LDTXHelper.writeDiagnosticsSamples(
      start: "1970-01-01T00:00:00.0001Z",
      end: "1970-01-01T00:00:00.0002Z",
      product: .ldtx,
      applicationVersion: "1.0",
      bundleIdentifier: bundleIdentifier,
      applicationSupportDirectory: root,
      output: output
    )
    try output.close()
    let samples = try JSONDecoder().decode(
      [DiagnosticsLoadSample].self, from: Data(contentsOf: outputURL))
    #expect(samples.isEmpty)

    let page = try LDTXHelper.queryDiagnosticsSamplePage(
      start: "1970-01-01T00:00:00.0001Z",
      end: "1970-01-01T00:00:00.0002Z",
      product: .ldtx,
      applicationVersion: "1.0",
      bundleIdentifier: bundleIdentifier,
      applicationSupportDirectory: root,
      limit: 10
    )
    #expect(page.samples.isEmpty)
    #expect(page.nextCursor == nil)
  }

  @Test func standaloneMCPRequiresDatabaseSelectors() {
    let tools = LDTXMCPServer.tools(requiresExplicitDiagnosticsSelectors: true)
    let diagnostics = tools.first { $0["name"] as? String == "diagnostics_query_samples" }
    #expect(diagnostics != nil)
    let schema = diagnostics?["inputSchema"] as? [String: Any]
    #expect(
      schema?["required"] as? [String] == ["start", "end", "appVersion", "bundleId"])
    let properties = schema?["properties"] as? [String: Any]
    #expect(properties?["path"] == nil)
    #expect(properties?["sql"] == nil)
    #expect(properties?["cursor"] != nil)
    #expect(properties?["limit"] != nil)
    #expect(properties?["bundleId"] != nil)
  }

  @Test func bundledMCPDefaultsDatabaseSelectorsFromItsApplication() {
    let tools = LDTXMCPServer.tools(requiresExplicitDiagnosticsSelectors: false)
    let diagnostics = tools.first { $0["name"] as? String == "diagnostics_query_samples" }
    let schema = diagnostics?["inputSchema"] as? [String: Any]
    #expect(schema?["required"] as? [String] == ["start", "end"])
  }

  @Test func remuxMCPAdvertisesCanvasSelectionOnlyForRemux() {
    let tools = LDTXMCPServer.tools(requiresExplicitDiagnosticsSelectors: false)
    let verify = tools.first { $0["name"] as? String == "record_verify" }
    let remux = tools.first { $0["name"] as? String == "record_remux" }
    let verifyProperties =
      (verify?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
    let remuxProperties =
      (remux?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]

    #expect(verifyProperties?["canvas"] == nil)
    #expect(remuxProperties?["canvas"] != nil)
  }
}
