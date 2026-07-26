// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import LDTXRecording

@main
struct LDTXHelper: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ldtx",
    abstract: "Inspect, verify, and remux LDTX recording packages, or run its stdio MCP server.",
    subcommands: [RecordCommand.self, MCPCommand.self]
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
    let outputURL = output.map { URL(fileURLWithPath: $0).standardizedFileURL }
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
      AudioTrack(identifier: $0.identifier, name: $0.name, mediaFile: $0.mediaPath, playlist: $0.playlistPath)
    }
  }
}
