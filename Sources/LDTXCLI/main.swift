// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import LDTXDiagnostics
import LDTXRecording

@main
struct LDTXHelper: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ldtx",
    abstract: "Inspect, verify, and remux LDTX recording packages, or run its stdio MCP server.",
    subcommands: [RecordCommand.self, DiagnosticsCommand.self, MCPCommand.self]
  )

  static func inspect(_ path: String) throws {
    let package = try RecordingPackage(contentsOf: URL(fileURLWithPath: path).standardizedFileURL)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(RecordingInspectionValue(package: package))
    print(String(decoding: data, as: UTF8.self))
  }

  static func verify(_ path: String, strict: Bool) async throws {
    let package = try RecordingPackage(contentsOf: URL(fileURLWithPath: path).standardizedFileURL)
    if strict { try package.requireFinalized() }
    let warnings = try await RecordingPackageVerifier().verify(package, strict: strict)
    for warning in warnings { writeWarning(warning) }
    print("OK: \(package.identifier) (\(package.audioTracks.count) audio tracks)")
  }

  static func remux(_ path: String, output: String?, replace: Bool, strict: Bool) async throws {
    let packageURL = URL(fileURLWithPath: path).standardizedFileURL
    let package = try RecordingPackage(contentsOf: packageURL)
    if strict { try package.requireFinalized() }
    let warnings = try await RecordingPackageVerifier().verify(package, strict: strict)
    for warning in warnings { writeWarning(warning) }
    let outputURL =
      output.map { URL(fileURLWithPath: $0).standardizedFileURL }
      ?? RecordingPackage.defaultRemuxOutputURL(for: packageURL)
    try await RecordingRemuxer().remux(
      package: package,
      to: outputURL,
      replaceExisting: replace
    )
    print(outputURL.path)
  }

  static func writeWarning(_ warning: String) {
    FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
  }
}

private enum DiagnosticsProductArgument: String, ExpressibleByArgument {
  case ldtx
  case tiny

  var value: DiagnosticsProduct { self == .ldtx ? .ldtx : .tiny }
}

private struct DiagnosticsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "diagnostics",
    abstract: "Query LDTX process load samples.",
    subcommands: [Samples.self]
  )

  struct Samples: AsyncParsableCommand {
    @Option(help: "Inclusive RFC 3339 UTC start time.") var start: String
    @Option(help: "Exclusive RFC 3339 UTC end time.") var end: String
    @Option(help: "Application product whose diagnostics database is queried.")
    var product: DiagnosticsProductArgument?
    @Option(name: .customLong("app-version"), help: "Application marketing version.")
    var appVersion: String?
    @Option(name: .customLong("bundle-id"), help: "Application bundle identifier.")
    var bundleID: String?

    mutating func run() async throws {
      try LDTXHelper.writeDiagnosticsSamples(
        start: start,
        end: end,
        product: product?.value,
        applicationVersion: appVersion,
        bundleIdentifier: bundleID
      )
    }
  }
}

private struct RecordCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "record",
    abstract: "Inspect, verify, and remux .ldtxrecord packages.",
    subcommands: [Inspect.self, Verify.self, Remux.self]
  )

  struct Inspect: AsyncParsableCommand {
    @Argument(help: "Path to an .ldtxrecord package.") var path: String
    mutating func run() async throws { try LDTXHelper.inspect(path) }
  }

  struct Verify: AsyncParsableCommand {
    @Argument(help: "Path to an .ldtxrecord package.") var path: String
    @Flag(help: "Reject an unfinalized package instead of attempting recovery.") var strict = false
    mutating func run() async throws { try await LDTXHelper.verify(path, strict: strict) }
  }

  struct Remux: AsyncParsableCommand {
    @Argument(help: "Path to an .ldtxrecord package.") var path: String
    @Option(name: [.short, .long], help: "Output MP4 path.") var output: String?
    @Flag(help: "Replace an existing output file.") var replace = false
    @Flag(help: "Reject an unfinalized package instead of attempting recovery.") var strict = false
    mutating func run() async throws {
      try await LDTXHelper.remux(path, output: output, replace: replace, strict: strict)
    }
  }
}

private struct MCPCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mcp",
    abstract: "Run the LDTX recording stdio MCP server."
  )

  mutating func run() async throws { try await LDTXMCPServer().run() }
}

extension LDTXHelper {
  static func writeDiagnosticsSamples(
    start: String,
    end: String,
    product: DiagnosticsProduct? = nil,
    applicationVersion: String? = nil,
    bundleIdentifier: String? = nil,
    applicationSupportDirectory: URL? = nil,
    output: FileHandle = .standardOutput
  ) throws {
    let (database, startMilliseconds, endMilliseconds) = try openDiagnosticsQuery(
      start: start,
      end: end,
      product: product,
      applicationVersion: applicationVersion,
      bundleIdentifier: bundleIdentifier,
      applicationSupportDirectory: applicationSupportDirectory
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try output.write(contentsOf: Data("[\n".utf8))
    var isFirst = true
    if startMilliseconds < endMilliseconds {
      try database.forEachSample(from: startMilliseconds, to: endMilliseconds) { sample in
        if !isFirst { try output.write(contentsOf: Data(",\n".utf8)) }
        try output.write(contentsOf: encoder.encode(sample))
        isFirst = false
      }
    }
    try output.write(contentsOf: Data("\n]\n".utf8))
  }

  static func queryDiagnosticsSamplePage(
    start: String,
    end: String,
    product: DiagnosticsProduct? = nil,
    applicationVersion: String? = nil,
    bundleIdentifier: String? = nil,
    applicationSupportDirectory: URL? = nil,
    cursor: DiagnosticsSampleCursor? = nil,
    limit: Int
  ) throws -> DiagnosticsSamplePage {
    let (database, startMilliseconds, endMilliseconds) = try openDiagnosticsQuery(
      start: start,
      end: end,
      product: product,
      applicationVersion: applicationVersion,
      bundleIdentifier: bundleIdentifier,
      applicationSupportDirectory: applicationSupportDirectory
    )
    guard startMilliseconds < endMilliseconds else {
      return DiagnosticsSamplePage(samples: [], nextCursor: nil)
    }
    return try database.samplePage(
      from: startMilliseconds, to: endMilliseconds, after: cursor, limit: limit)
  }

  private static func openDiagnosticsQuery(
    start: String,
    end: String,
    product: DiagnosticsProduct?,
    applicationVersion: String?,
    bundleIdentifier: String?,
    applicationSupportDirectory: URL?
  ) throws -> (DiagnosticsDatabase, Int64, Int64) {
    let startDate = try diagnosticsDate(start)
    let endDate = try diagnosticsDate(end)
    guard startDate < endDate else { throw DiagnosticsDatabaseError.invalidTimeRange }
    let hostBundle = diagnosticsHostApplicationBundle()
    guard let resolvedBundleIdentifier = bundleIdentifier ?? hostBundle?.bundleIdentifier else {
      throw ValidationError("--bundle-id is required outside an application bundle.")
    }
    let resolvedProduct =
      product ?? (resolvedBundleIdentifier.contains("LDTXTiny") ? .tiny : .ldtx)
    guard
      let resolvedVersion = applicationVersion
        ?? hostBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    else {
      throw ValidationError("--app-version is required when the Helper has no application version.")
    }
    let location = try DiagnosticsDatabaseLocation(
      product: resolvedProduct,
      bundleIdentifier: resolvedBundleIdentifier,
      applicationVersion: resolvedVersion,
      applicationSupportDirectory: applicationSupportDirectory
    )
    let database = try DiagnosticsDatabase(location: location, createIfMissing: false)
    return (
      database,
      diagnosticsUnixMillisecondsCeiling(startDate),
      diagnosticsUnixMillisecondsCeiling(endDate)
    )
  }

  private static func diagnosticsUnixMillisecondsCeiling(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded(.up))
  }

  static func diagnosticsHostApplicationBundle() -> Bundle? {
    var candidate = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
      .deletingLastPathComponent()
    while candidate.path != "/" {
      if candidate.pathExtension == "app" { return Bundle(url: candidate) }
      candidate.deleteLastPathComponent()
    }
    return nil
  }

  private static func diagnosticsDate(_ value: String) throws -> Date {
    do {
      return try Date(value, strategy: .iso8601)
    } catch {
      throw ValidationError("Invalid RFC 3339 timestamp: \(value)")
    }
  }
}

struct RecordingInspectionValue: Encodable {
  struct AudioTrack: Encodable {
    var identifier: String
    var name: String
    var mediaFile: String
    var playlist: String?
  }

  var formatVersion: Int
  var identifier: String
  var finalized: Bool
  var manifestFile: String
  var mainMediaFile: String
  var mainPlaylist: String?
  var masterPlaylist: String?
  var audioTracks: [AudioTrack]

  init(package: RecordingPackage) {
    formatVersion = package.formatVersion
    identifier = package.identifier
    finalized = package.isFinalized
    manifestFile = package.manifestPath
    mainMediaFile = package.mainMediaPath
    mainPlaylist = package.mainPlaylistPath
    masterPlaylist = package.masterPlaylistPath
    audioTracks = package.audioTracks.map {
      AudioTrack(
        identifier: $0.identifier, name: $0.name, mediaFile: $0.mediaPath, playlist: $0.playlistPath
      )
    }
  }
}
