// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCorelibs
import LDTXRecording
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletStore

public struct CLIValidationError: Error, LocalizedError {
  private let message: String

  public init(_ message: String) {
    self.message = message
  }

  public var errorDescription: String? { message }
}

enum ParsedArg: Equatable {
  case opt(key: String, value: String?, combined: Bool)
  case posArg(String)
}

func parseArgs(_ args: ArraySlice<String>) -> [ParsedArg] {
  var parsedArgs: [ParsedArg] = []
  var tail = args
  while let arg = tail.popFirst() {
    if arg == "--" {
      parsedArgs.append(contentsOf: tail.map(ParsedArg.posArg))
      return parsedArgs
    } else if let match = arg.wholeMatch(of: /(--[^=]+)=(.*)/.dotMatchesNewlines()) {
      parsedArgs.append(
        .opt(
          key: String(match.output.1), value: String(match.output.2), combined: true))
    } else if arg.hasPrefix("--") {
      if tail.first?.hasPrefix("--") == false {
        parsedArgs.append(.opt(key: arg, value: tail.popFirst(), combined: false))
      } else {
        parsedArgs.append(.opt(key: arg, value: nil, combined: false))
      }
    } else {
      parsedArgs.append(.posArg(arg))
    }
  }
  return parsedArgs
}

private struct CLIArguments {
  var positionals: [String] = []
  var values: [String: String] = [:]
  var flags: Set<String> = []

  static func parse(
    _ arguments: [String], valueOptions: Set<String> = [], flags: Set<String> = []
  ) throws -> CLIArguments {
    var result = CLIArguments()
    let normalizedArguments = arguments.map { $0 == "-o" ? "--output" : $0 }
    for argument in parseArgs(normalizedArguments[...]) {
      switch argument {
      case .posArg(let value):
        result.positionals.append(value)
      case .opt(let key, let value, let combined):
        if valueOptions.contains(key) {
          guard let value else {
            throw CLIValidationError("Missing value for \(key).")
          }
          guard result.values[key] == nil else {
            throw CLIValidationError("\(key) may only be specified once.")
          }
          result.values[key] = value
        } else if flags.contains(key) {
          guard !combined else {
            throw CLIValidationError("\(key) does not accept a value.")
          }
          guard result.flags.insert(key).inserted else {
            throw CLIValidationError("\(key) may only be specified once.")
          }
          // parseArgs treats the next non-option token as an option value. For
          // boolean flags, preserve that token as a positional argument.
          if let value { result.positionals.append(value) }
        } else {
          throw CLIValidationError("Unknown option: \(key)")
        }
      }
    }
    return result
  }
}

public enum LdtxCLI {
  public static func parseAsRoot(_ arguments: [String]) throws -> Any {
    guard let command = arguments.first else {
      throw CLIValidationError("Expected 'workspace' or 'record'.")
    }
    switch command {
    case "workspace":
      return try WorkspaceCommand.parse(Array(arguments.dropFirst()))
    case "record":
      return try RecordCommand.parse(Array(arguments.dropFirst()))
    default:
      throw CLIValidationError("Unknown command: \(command)")
    }
  }

  public static func run(arguments: [String] = Array(CommandLine.arguments.dropFirst()))
    async throws
  {
    if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
      print("Usage: ldtx <workspace create|dump|validate|record inspect|verify|remux> …")
      return
    }
    let command = try parseAsRoot(arguments)
    switch command {
    case let command as WorkspaceCommand.Create: try await command.run()
    case let command as WorkspaceCommand.Dump: try command.run()
    case let command as WorkspaceCommand.Validate: try command.run()
    case let command as RecordCommand.Inspect: try await command.run()
    case let command as RecordCommand.Verify: try await command.run()
    case let command as RecordCommand.Remux: try await command.run()
    default: throw CLIValidationError("Unsupported command.")
    }
  }

  public static func inspect(_ path: String) throws {
    let package = try RecordingPackage(contentsOf: URL(fileURLWithPath: path).standardizedFileURL)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(RecordingInspectionValue(package: package))
    print(String(decoding: data, as: UTF8.self))
  }

  public static func verify(_ path: String, strict: Bool) async throws {
    let package = try RecordingPackage(contentsOf: URL(fileURLWithPath: path).standardizedFileURL)
    if strict { try package.requireFinalized() }
    let warnings = try await RecordingPackageVerifier().verify(package, strict: strict)
    for warning in warnings { writeWarning(warning) }
    print("OK: \(package.identifier) (\(package.audioTracks.count) audio tracks)")
  }

  public static func remux(
    _ path: String,
    output: String?,
    replace: Bool,
    strict: Bool,
    canvas: RecordingCanvas?
  ) async throws {
    let packageURL = URL(fileURLWithPath: path).standardizedFileURL
    let package = try RecordingPackage(contentsOf: packageURL)
    if strict { try package.requireFinalized() }
    let warnings = try await RecordingPackageVerifier().verify(
      package, strict: strict, canvas: canvas)
    for warning in warnings { writeWarning(warning) }
    let outputURL =
      output.map { URL(fileURLWithPath: $0).standardizedFileURL }
      ?? RecordingPackage.defaultRemuxOutputURL(for: packageURL)
    try await RecordingRemuxer().remux(
      package: package,
      to: outputURL,
      replaceExisting: replace,
      canvas: canvas
    )
    print(outputURL.path)
  }

  public static func writeWarning(_ warning: String) {
    FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
  }
}

public enum WorkspaceCommand {
  static func parse(_ arguments: [String]) throws -> Any {
    guard let command = arguments.first else {
      throw CLIValidationError("Expected 'create', 'dump', or 'validate'.")
    }
    let tail = Array(arguments.dropFirst())
    switch command {
    case "create": return try Create.parse(tail)
    case "dump": return try Dump.parse(tail)
    case "validate": return try Validate.parse(tail)
    default: throw CLIValidationError("Unknown Workspace command: \(command)")
    }
  }

  struct Create {
    let package: String
    let name: String?
    let json: String?
    let preferencesJSON: String?

    static func parse(_ arguments: [String]) throws -> Create {
      let parsed = try CLIArguments.parse(
        arguments, valueOptions: ["--name", "--json", "--preferences-json"])
      guard parsed.positionals.count == 1, let package = parsed.positionals.first else {
        throw CLIValidationError("workspace create requires one package path.")
      }
      return Create(
        package: package,
        name: parsed.values["--name"],
        json: parsed.values["--json"],
        preferencesJSON: parsed.values["--preferences-json"])
    }

    func run() async throws {
      let url = URL(fileURLWithPath: package).standardizedFileURL
      guard preferencesJSON == nil || json != nil else {
        throw CLIValidationError("--preferences-json requires --json")
      }
      let command = self
      try coordinateWorkspace(at: url, writing: true) { url in
        let createdPackageDirectory = !FileManager.default.fileExists(atPath: url.path)
        guard createdPackageDirectory else {
          throw CLIValidationError("Workspace already exists: \(url.path)")
        }
        do {
          var workspace: WorkspaceV4Bundle
          if let json = command.json {
            var definition = try JSONDecoder().decode(
              Ldtx_Workspace_V4_WorkspaceDefinitionV4.self,
              from: Data(contentsOf: URL(fileURLWithPath: json)))
            if let name = command.name { definition.displayName = name }
            let preferences =
              try command.preferencesJSON.map {
                try JSONDecoder().decode(
                  Ldtx_Workspace_V4_WorkspacePreferencesV4.self,
                  from: Data(contentsOf: URL(fileURLWithPath: $0)))
              } ?? Ldtx_Workspace_V4_WorkspacePreferencesV4()
            workspace = WorkspaceV4Bundle(
              definition: definition,
              preferences: preferences)
          } else {
            workspace = WorkspaceV4Bundle(
              definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4.with {
                $0.displayName = command.name ?? url.deletingPathExtension().lastPathComponent
              },
              preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4())
          }
          try WorkspaceBundleValidatorV4.validate(workspace)
          try workspace.definition.validateRichTextDocuments()
          guard var writer = WorkspaceBundleWriterV4(at: url) else {
            throw CLIValidationError("Could not initialize Workspace writer: \(url.path)")
          }
          let definitionExternalID = writer.makeExternalID()
          try writer.write(definition: workspace.definition, externalID: definitionExternalID)
          workspace.definitionExternalID = definitionExternalID.uuidString.lowercased()
          let preferencesExternalID = writer.makeExternalID()
          try writer.write(preferences: workspace.preferences, externalID: preferencesExternalID)
          workspace.preferencesExternalID = preferencesExternalID.uuidString.lowercased()
          let outputSettingsExternalID = writer.makeExternalID()
          try writer.write(
            outputSettings: workspace.outputSettings, externalID: outputSettingsExternalID)
          workspace.outputSettingsExternalID = outputSettingsExternalID.uuidString.lowercased()
          print("Created Workspace v4: \(url.path)")
        } catch {
          if createdPackageDirectory {
            try? FileManager.default.removeItem(at: url)
          }
          throw error
        }
      }
    }
  }

  struct Dump {
    let package: String
    let program: String?

    static func parse(_ arguments: [String]) throws -> Dump {
      let parsed = try CLIArguments.parse(arguments, valueOptions: ["--program"])
      guard parsed.positionals.count == 1, let package = parsed.positionals.first else {
        throw CLIValidationError("workspace dump requires one package path.")
      }
      return Dump(package: package, program: parsed.values["--program"])
    }

    func run() throws {
      let url = URL(fileURLWithPath: package).standardizedFileURL
      let selectedProgram = program
      try coordinateWorkspace(at: url, writing: false) { url in
        let dump = try workspaceV4DebugDump(
          at: url, programName: selectedProgram)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(dump), as: UTF8.self))
      }
    }
  }

  struct Validate {
    let package: String

    static func parse(_ arguments: [String]) throws -> Validate {
      let parsed = try CLIArguments.parse(arguments)
      guard parsed.positionals.count == 1, let package = parsed.positionals.first else {
        throw CLIValidationError("workspace validate requires one package path.")
      }
      return Validate(package: package)
    }

    func run() throws {
      let url = URL(fileURLWithPath: package).standardizedFileURL
      try coordinateWorkspace(at: url, writing: false) { url in
        let reader: WorkspaceBundleReaderV4
        switch makeWorkspaceBundleReader(at: url) {
        case .v4(let v4Reader):
          reader = v4Reader
        case .failure:
          throw CLIValidationError("Unsupported Workspace format")
        }
        let workspace = try reader.read()
        try WorkspaceBundleValidatorV4.validate(workspace)
        try workspace.definition.validateRichTextDocuments()
        print("OK: Workspace v4 \(url.path)")
      }
    }
  }
}

public struct WorkspaceV4DebugDump: Codable, Equatable {
  static let format = "ldtx-workspace-debug-dump-v4"
  public struct Program: Codable, Equatable {
    public var internalID: Int64
    public var displayName: String
    public var landscapeVideoLayerInternalIDs: [Int64]
    public var portraitVideoLayerInternalIDs: [Int64]
  }
  public var format: String
  public var definitionExternalID: String
  public var preferencesExternalID: String
  public var displayName: String
  public var programs: [Program]
}

public func workspaceV4DebugDump(
  at packageURL: URL, programName: String? = nil
) throws -> WorkspaceV4DebugDump {
  let reader = makeWorkspaceBundleReader(at: packageURL)
  let v4Reader: WorkspaceBundleReaderV4
  switch reader {
  case .v4(let reader):
    v4Reader = reader
  case .failure:
    throw CLIValidationError("Unsupported Workspace format")
  }
  let workspace = try v4Reader.read()
  let programs = workspace.definition.programs.filter {
    programName == nil || $0.displayName == programName
  }
  guard programName == nil || !programs.isEmpty else {
    throw CLIValidationError("Program not found: \(programName ?? "")")
  }
  return WorkspaceV4DebugDump(
    format: WorkspaceV4DebugDump.format,
    definitionExternalID: workspace.definitionExternalID ?? "",
    preferencesExternalID: workspace.preferencesExternalID ?? "",
    displayName: workspace.definition.displayName ?? "",
    programs: try programs.map {
      guard let id = $0.internalID, let name = $0.displayName else {
        throw CLIValidationError("Program is missing its identifier or display name")
      }
      return WorkspaceV4DebugDump.Program(
        internalID: id, displayName: name,
        landscapeVideoLayerInternalIDs: workspace.preferences.landscapeProgramPreferences[
          id]?.videoLayerInternalIds ?? [],
        portraitVideoLayerInternalIDs: workspace.preferences.portraitProgramPreferences[
          id]?.videoLayerInternalIds ?? [])
    })
}

public enum RecordingCanvasArgument: String {
  case landscape
  case portrait

  var value: RecordingCanvas {
    self == .landscape ? .landscape : .portrait
  }
}

public enum RecordCommand {
  static func parse(_ arguments: [String]) throws -> Any {
    guard let command = arguments.first else {
      throw CLIValidationError("Expected 'inspect', 'verify', or 'remux'.")
    }
    let tail = Array(arguments.dropFirst())
    switch command {
    case "inspect": return try Inspect.parse(tail)
    case "verify": return try Verify.parse(tail)
    case "remux": return try Remux.parse(tail)
    default: throw CLIValidationError("Unknown record command: \(command)")
    }
  }

  struct Inspect {
    let path: String
    static func parse(_ arguments: [String]) throws -> Inspect {
      let parsed = try CLIArguments.parse(arguments)
      guard parsed.positionals.count == 1, let path = parsed.positionals.first else {
        throw CLIValidationError("record inspect requires one package path.")
      }
      return Inspect(path: path)
    }
    func run() async throws { try LdtxCLI.inspect(path) }
  }

  struct Verify {
    let path: String
    let strict: Bool
    static func parse(_ arguments: [String]) throws -> Verify {
      let parsed = try CLIArguments.parse(arguments, flags: ["--strict"])
      guard parsed.positionals.count == 1, let path = parsed.positionals.first else {
        throw CLIValidationError("record verify requires one package path.")
      }
      return Verify(path: path, strict: parsed.flags.contains("--strict"))
    }
    func run() async throws { try await LdtxCLI.verify(path, strict: strict) }
  }

  struct Remux {
    let path: String
    let output: String?
    let replace: Bool
    let strict: Bool
    let canvas: RecordingCanvasArgument?

    static func parse(_ arguments: [String]) throws -> Remux {
      let parsed = try CLIArguments.parse(
        arguments,
        valueOptions: ["-o", "--output", "--canvas"],
        flags: ["--replace", "--strict"])
      guard parsed.positionals.count == 1, let path = parsed.positionals.first else {
        throw CLIValidationError("record remux requires one package path.")
      }
      let canvas: RecordingCanvasArgument?
      if let rawValue = parsed.values["--canvas"] {
        guard let parsedCanvas = RecordingCanvasArgument(rawValue: rawValue) else {
          throw CLIValidationError("--canvas must be 'landscape' or 'portrait'.")
        }
        canvas = parsedCanvas
      } else {
        canvas = nil
      }
      return Remux(
        path: path,
        output: parsed.values["--output"],
        replace: parsed.flags.contains("--replace"),
        strict: parsed.flags.contains("--strict"),
        canvas: canvas)
    }

    func run() async throws {
      try await LdtxCLI.remux(
        path, output: output, replace: replace, strict: strict, canvas: canvas?.value)
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

/// Keeps CLI package access coordinated without holding a lifetime lock.
private func coordinateWorkspace<T>(
  at url: URL, writing: Bool, _ accessor: (URL) throws -> T
) throws -> T {
  let coordinator = NSFileCoordinator()
  var error: NSError?
  var result: Result<T, Error>?
  if writing {
    coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &error) {
      coordinatedURL in
      result = Result { try accessor(coordinatedURL) }
    }
  } else {
    coordinator.coordinate(readingItemAt: url, options: [], error: &error) { coordinatedURL in
      result = Result { try accessor(coordinatedURL) }
    }
  }
  if let error { throw error }
  guard let result else { throw CocoaError(.fileReadUnknown) }
  return try result.get()
}
