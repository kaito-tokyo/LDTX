// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import LDTXAutomation
import LDTXCapture
import LDTXRecording
import LDTXWorkspace

@main
struct LDTXHelper: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ldtx",
    abstract: "Inspect and control LDTX workspaces and recordings, or run its stdio MCP server.",
    subcommands: [WorkspaceCommand.self, RecordCommand.self, MCPCommand.self]
  )

  fileprivate static func runWorkspace(arguments: [String]) async throws {
    guard let command = arguments.first else {
      throw CLIError.usage
    }

    let invocation = try workspaceInvocation(Array(arguments.dropFirst()))
    let rest = invocation.arguments
    switch command {
    case "windows":
      try printWindows()
    case "input-devices", "print-input-devices":
      try printInputDevices()
    case "get-input-devices":
      try printWorkspaceInputDevices(workspaceURL: resolveWorkspaceURL(invocation.selector))
    case "select-input-device":
      try selectInputDevice(
        arguments: rest,
        workspaceURL: resolveWorkspaceURL(invocation.selector)
      )
    case "select-youtube-livebroadcast":
      try selectYouTubeLiveBroadcast(
        arguments: rest,
        workspaceURL: resolveWorkspaceURL(invocation.selector)
      )
    case "get-program":
      try printActiveProgramDefinition(workspaceURL: resolveWorkspaceURL(invocation.selector))
    case "program-select":
      try programSelect(arguments: rest, workspaceURL: resolveWorkspaceURL(invocation.selector))
    case "record-start":
      try printCommandResult(
        sendCommand(
          method: LDTXAutomationMethod.recordStart,
          workspaceURL: resolveWorkspaceURL(invocation.selector)
        ))
    case "record-stop":
      try printCommandResult(
        sendCommand(
          method: LDTXAutomationMethod.recordStop,
          workspaceURL: resolveWorkspaceURL(invocation.selector)
        ))
    case "record-split":
      try printCommandResult(
        sendCommand(
          method: LDTXAutomationMethod.recordSplit,
          workspaceURL: resolveWorkspaceURL(invocation.selector)
        ))
    case "start-output":
      try printCommandResult(
        sendCommand(
          method: LDTXAutomationMethod.outputStart,
          workspaceURL: resolveWorkspaceURL(invocation.selector)
        ))
    case "stop-output":
      try printCommandResult(
        sendCommand(
          method: LDTXAutomationMethod.outputStop,
          workspaceURL: resolveWorkspaceURL(invocation.selector)
        ))
    case "output-settings":
      try outputSettings(
        arguments: rest,
        workspaceURL: resolveWorkspaceURL(invocation.selector)
      )
    case "selected-program-name":
      try printSelectedProgramName(workspaceURL: resolveWorkspaceURL(invocation.selector))
    default:
      throw CLIError.usage
    }
  }

  fileprivate static func recording(arguments: [String]) async throws {
    guard let subcommand = arguments.first else {
      throw CLIError.recordingUsage
    }
    let rest = Array(arguments.dropFirst())
    switch subcommand {
    case "inspect":
      guard rest.count == 1 else { throw CLIError.recordingUsage }
      let package = try RecordingPackage(contentsOf: fileURL(rest[0]))
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(RecordingInspectionValue(package: package))
      print(String(decoding: data, as: UTF8.self))
    case "verify":
      let strict = rest.contains("--strict")
      let paths = rest.filter { $0 != "--strict" }
      guard paths.count == 1 else { throw CLIError.recordingUsage }
      let package = try RecordingPackage(contentsOf: fileURL(paths[0]))
      let finalizationWarnings = try checkFinalization(of: package, strict: strict)
      let verificationWarnings = try await RecordingPackageVerifier().verify(
        package, strict: strict)
      for warning in finalizationWarnings + verificationWarnings { writeWarning(warning) }
      print("OK: \(package.identifier) (\(package.audioTracks.count) audio tracks)")
    case "remux":
      try await remuxRecording(arguments: rest)
    default:
      throw CLIError.recordingUsage
    }
  }

  private static func remuxRecording(arguments: [String]) async throws {
    var packagePath: String?
    var outputPath: String?
    var replaceExisting = false
    var strict = false
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--output", "-o":
        index += 1
        guard index < arguments.count else { throw CLIError.recordingUsage }
        outputPath = arguments[index]
      case "--replace":
        replaceExisting = true
      case "--strict":
        strict = true
      default:
        guard packagePath == nil else { throw CLIError.recordingUsage }
        packagePath = arguments[index]
      }
      index += 1
    }
    guard let packagePath else { throw CLIError.recordingUsage }

    let packageURL = fileURL(packagePath)
    let package = try RecordingPackage(contentsOf: packageURL)
    let finalizationWarnings = try checkFinalization(of: package, strict: strict)
    let verificationWarnings = try await RecordingPackageVerifier().verify(package, strict: strict)
    for warning in finalizationWarnings + verificationWarnings { writeWarning(warning) }
    let outputURL =
      outputPath.map(fileURL)
      ?? RecordingPackage.defaultRemuxOutputURL(for: packageURL)
    try await RecordingRemuxer().remux(
      package: package,
      to: outputURL,
      replaceExisting: replaceExisting
    )
    print(outputURL.path)
  }

  private static func checkFinalization(of package: RecordingPackage, strict: Bool) throws
    -> [String]
  {
    if strict {
      try package.requireFinalized()
      return []
    }
    return package.isFinalized
      ? [] : ["Recording package is not finalized; attempting recovery."]
  }

  private static func writeWarning(_ warning: String) {
    FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
  }

  private static func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: path).standardizedFileURL
  }

  private static func printInputDevices() throws {
    let manager = CaptureSessionManager()
    let payload = InputDevicesPayload(
      cameras: manager.availableCameras().map(InputCameraDevicePayload.init),
      audioDevices: manager.availableAudioDevices().map(InputAudioDevicePayload.init)
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(payload)
    print(String(decoding: data, as: UTF8.self))
  }

  private static func printWorkspaceInputDevices(workspaceURL: URL) throws {
    let response = try sendRequest(
      JSONRPCRequest(
        id: .string(UUID().uuidString),
        method: LDTXAutomationMethod.inputDevicesGet,
        params: targetedParams(workspaceURL: workspaceURL)
      ))
    let result = try responseResult(response)
    let inputDevices = try Ldtx_Automation_V1_InputDevicesResult(jsonRPCValue: result)
    let payload = inputDevices.inputDevices.map(\.workspaceRecord)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(payload)
    print(String(decoding: data, as: UTF8.self))
  }

  private static func selectInputDevice(arguments: [String], workspaceURL: URL) throws {
    guard let workspaceInputDeviceName = arguments.first else {
      throw CLIError.failure(
        "Usage: ldtx select-input-device <workspace-input-device-name> <physical-device-id>|--none"
      )
    }
    let rest = Array(arguments.dropFirst())
    guard rest.count == 1 else {
      throw CLIError.failure(
        "Usage: ldtx select-input-device <workspace-input-device-name> <physical-device-id>|--none"
      )
    }

    var params = Ldtx_Automation_V1_InputDeviceSelectParams()
    params.workspaceInputDeviceName = workspaceInputDeviceName
    if rest[0] != "--none" {
      let physicalDeviceID = rest[0].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !physicalDeviceID.isEmpty else {
        throw CLIError.failure("Physical device ID must not be empty.")
      }
      params.physicalDeviceID = physicalDeviceID
    }

    try printCommandResult(
      sendCommand(
        method: LDTXAutomationMethod.inputDeviceSelect,
        workspaceURL: workspaceURL,
        params: params.jsonRPCValue()
      ))
  }

  private static func selectYouTubeLiveBroadcast(arguments: [String], workspaceURL: URL) throws {
    guard arguments.count == 1 else {
      throw CLIError.failure("Usage: ldtx select-youtube-livebroadcast <broadcast-id>|--none")
    }

    let broadcastID = arguments[0].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !broadcastID.isEmpty else {
      throw CLIError.failure("YouTube liveBroadcast ID must not be empty.")
    }

    var youtube = Ldtx_Automation_V1_YouTubeOutputSettings()
    if broadcastID != "--none" {
      youtube.existingBroadcastID = broadcastID
    } else {
      youtube.existingBroadcastID = ""
    }

    var settings = Ldtx_Automation_V1_OutputSettings()
    settings.youtube = youtube

    try printCommandResult(
      sendCommand(
        method: LDTXAutomationMethod.outputSettingsSet,
        workspaceURL: workspaceURL,
        params: settings.jsonRPCValue()
      ))
  }

  private static func programSelect(arguments: [String], workspaceURL: URL) throws {
    let isScratchPad = arguments == ["--scratch-pad"]
    let name = isScratchPad ? "" : arguments.joined(separator: " ")
    guard isScratchPad || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CLIError.failure("Usage: ldtx program-select <name>|--scratch-pad")
    }

    var params = Ldtx_Automation_V1_ProgramSelectParams()
    params.name = name
    params.isScratchPad = isScratchPad
    try printCommandResult(
      sendCommand(
        method: LDTXAutomationMethod.programSelect,
        workspaceURL: workspaceURL,
        params: params.jsonRPCValue()
      ))
  }

  private static func printActiveProgramDefinition(workspaceURL: URL) throws {
    let response = try sendRequest(
      JSONRPCRequest(
        id: .string(UUID().uuidString),
        method: LDTXAutomationMethod.programGet,
        params: targetedParams(workspaceURL: workspaceURL)
      ))
    let result = try responseResult(response)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(result)
    print(String(decoding: data, as: UTF8.self))
  }

  private static func printSelectedProgramName(workspaceURL: URL) throws {
    let response = try sendRequest(
      JSONRPCRequest(
        id: .string(UUID().uuidString),
        method: LDTXAutomationMethod.selectedProgramName,
        params: targetedParams(workspaceURL: workspaceURL)
      ))
    let result = try responseResult(response)
    let selectedProgram = try Ldtx_Automation_V1_SelectedProgramNameResult(jsonRPCValue: result)
    print(selectedProgram.name)
  }

  private static func outputSettings(arguments: [String], workspaceURL: URL) throws {
    guard let subcommand = arguments.first else {
      throw CLIError.failure("Usage: ldtx output-settings get|set <json>|set --file <path>|set -")
    }

    switch subcommand {
    case "get":
      guard arguments.count == 1 else {
        throw CLIError.failure("Usage: ldtx output-settings get")
      }
      try printOutputSettings(workspaceURL: workspaceURL)
    case "set":
      let settings = try outputSettingsFromJSONArguments(Array(arguments.dropFirst()))
      try printCommandResult(
        sendCommand(
          method: LDTXAutomationMethod.outputSettingsSet,
          workspaceURL: workspaceURL,
          params: settings.jsonRPCValue()
        ))
    default:
      throw CLIError.failure("Usage: ldtx output-settings get|set <json>|set --file <path>|set -")
    }
  }

  private static func printOutputSettings(workspaceURL: URL) throws {
    let response = try sendRequest(
      JSONRPCRequest(
        id: .string(UUID().uuidString),
        method: LDTXAutomationMethod.outputSettingsGet,
        params: targetedParams(workspaceURL: workspaceURL)
      ))
    let result = try responseResult(response)
    let settings = try Ldtx_Automation_V1_OutputSettings(jsonRPCValue: result)
    let data = try JSONEncoder().encode(settings.jsonRPCValue())
    print(String(decoding: data, as: UTF8.self))
  }

  private static func outputSettingsFromJSONArguments(
    _ arguments: [String]
  ) throws -> Ldtx_Automation_V1_OutputSettings {
    let data: Data
    if arguments == ["-"] {
      data = FileHandle.standardInput.readDataToEndOfFile()
    } else if arguments.first == "--file" {
      guard arguments.count == 2 else {
        throw CLIError.failure("Usage: ldtx output-settings set --file <path>")
      }
      data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    } else {
      let json = arguments.joined(separator: " ")
      guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CLIError.failure("Usage: ldtx output-settings set <json>")
      }
      data = Data(json.utf8)
    }

    do {
      let value = try JSONDecoder().decode(JSONValue.self, from: data)
      return try Ldtx_Automation_V1_OutputSettings(jsonRPCValue: value)
    } catch {
      throw CLIError.failure(
        "Output Settings JSON could not be parsed: \(error.localizedDescription)")
    }
  }

  private static func workspaceInvocation(_ arguments: [String]) throws
    -> (selector: String?, arguments: [String])
  {
    var selector: String?
    var remaining: [String] = []
    var index = 0
    while index < arguments.count {
      if arguments[index] == "--workspace" {
        guard selector == nil, index + 1 < arguments.count else {
          throw CLIError.failure("--workspace requires exactly one value.")
        }
        selector = arguments[index + 1]
        index += 2
      } else {
        remaining.append(arguments[index])
        index += 1
      }
    }
    return (selector, remaining)
  }

  private static func fetchWindows() throws -> LDTXAutomationWindowList {
    let response = try sendRequest(
      JSONRPCRequest(
        id: .string(UUID().uuidString),
        method: LDTXAutomationMethod.windowList
      ))
    return try LDTXAutomationWindowList.ldtxDecode(jsonRPCValue: responseResult(response))
  }

  private static func printWindows() throws {
    let windows = try fetchWindows()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(windows), as: UTF8.self))
  }

  private static func resolveWorkspaceURL(_ selector: String?) throws -> URL {
    let workspaces = try fetchWindows().windows.filter { $0.kind == "workspace" }
    guard !workspaces.isEmpty else {
      throw CLIError.failure("No Workspace window is open.")
    }

    let matches: [LDTXAutomationWindow]
    if let selector {
      if let candidate = URL(string: selector), candidate.scheme != nil,
        let canonical = try? LDTXResourceURL.canonicalWorkspaceURL(candidate)
      {
        matches = workspaces.filter { $0.url == canonical.absoluteString }
      } else {
        let fileURL = URL(fileURLWithPath: selector).standardizedFileURL
        matches = workspaces.filter { window in
          window.documentURL == fileURL.absoluteString
            || window.title == selector
            || window.documentURL.flatMap(URL.init(string:))?.lastPathComponent == selector
            || window.documentURL.flatMap(URL.init(string:))?
              .deletingPathExtension().lastPathComponent == selector
        }
      }
    } else {
      matches = workspaces
    }

    guard matches.count == 1, let match = matches.first else {
      if matches.isEmpty {
        throw CLIError.failure("No open Workspace matches: \(selector ?? "<unspecified>")")
      }
      let candidates = matches.map { "\($0.title): \($0.url)" }.joined(separator: "\n")
      throw CLIError.failure("Workspace selector is ambiguous. Use a formal URL:\n\(candidates)")
    }
    return try LDTXResourceURL.canonicalWorkspaceURL(match.url)
  }

  private static func targetedParams(workspaceURL: URL, arguments: JSONValue? = nil) -> JSONValue {
    var object: [String: JSONValue]
    if case .object(let argumentsObject) = arguments {
      object = argumentsObject
    } else {
      object = [:]
    }
    object["workspaceURL"] = .string(workspaceURL.absoluteString)
    return .object(object)
  }

  private static func sendCommand(
    method: String,
    workspaceURL: URL,
    params: JSONValue? = nil
  ) throws
    -> Ldtx_Automation_V1_CommandResult
  {
    let response = try sendRequest(
      JSONRPCRequest(
        id: .string(UUID().uuidString),
        method: method,
        params: targetedParams(workspaceURL: workspaceURL, arguments: params)
      ))
    let result = try responseResult(response)
    return try Ldtx_Automation_V1_CommandResult(jsonRPCValue: result)
  }

  private static func sendRequest(_ request: JSONRPCRequest) throws -> JSONRPCResponse {
    let response = try LDTXBrokerClient.send(request, service: cliAutomationServiceIdentity)
    if let error = response.error {
      throw CLIError.failure(error.message)
    }
    return response
  }

  private static func responseResult(_ response: JSONRPCResponse) throws -> JSONValue {
    guard let result = response.result else {
      throw CLIError.failure("Broker response did not include a result.")
    }
    return result
  }

  private static func printCommandResult(_ result: Ldtx_Automation_V1_CommandResult) throws {
    if result.message.isEmpty {
      print(result.ok ? "OK" : "Failed")
    } else {
      print(result.message)
    }
    guard result.ok else {
      throw CLIError(
        exitCode: 1, message: result.message.isEmpty ? "Command failed." : result.message)
    }
  }
}

private struct WorkspaceCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "workspace",
    abstract: "Control the active LDTX workspace."
  )

  @Argument(parsing: .captureForPassthrough)
  var arguments: [String] = []

  mutating func run() async throws {
    do {
      try await LDTXHelper.runWorkspace(arguments: arguments)
    } catch let error as CLIError {
      throw ValidationError(error.message)
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
    static let configuration = CommandConfiguration(
      abstract: "Print recording information as JSON.")

    @Argument(help: "Path to an .ldtxrecord package.")
    var path: String

    mutating func run() async throws {
      try await LDTXHelper.recording(arguments: ["inspect", path])
    }
  }

  struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Verify a recording package.")

    @Argument(help: "Path to an .ldtxrecord package.")
    var path: String

    @Flag(help: "Reject an unfinalized package instead of attempting recovery.")
    var strict = false

    mutating func run() async throws {
      var arguments = ["verify", path]
      if strict { arguments.append("--strict") }
      try await LDTXHelper.recording(arguments: arguments)
    }
  }

  struct Remux: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remux a recording package to MP4.")

    @Argument(help: "Path to an .ldtxrecord package.")
    var path: String

    @Option(name: [.short, .long], help: "Output MP4 path.")
    var output: String?

    @Flag(help: "Replace an existing output file.")
    var replace = false

    @Flag(help: "Reject an unfinalized package instead of attempting recovery.")
    var strict = false

    mutating func run() async throws {
      var arguments = [path]
      if let output { arguments += ["--output", output] }
      if replace { arguments.append("--replace") }
      if strict { arguments.append("--strict") }
      try await LDTXHelper.recording(arguments: ["remux"] + arguments)
    }
  }
}

private struct MCPCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mcp",
    abstract: "Run the LDTX recording stdio MCP server."
  )

  mutating func run() async throws {
    try await LDTXMCPServer().run()
  }
}

private struct CLIError: Error {
  var exitCode: Int
  var message: String

  static var usage: CLIError {
    CLIError(
      exitCode: 64,
      message: """
        Usage:
          ldtx workspace windows
          ldtx workspace <command> [--workspace <formal-url|path|title>]
          ldtx workspace get-input-devices
          ldtx workspace get-program
          ldtx workspace print-input-devices
          ldtx workspace input-devices
          ldtx workspace select-input-device <workspace-input-device-name> <physical-device-id>
          ldtx workspace select-input-device <workspace-input-device-name> --none
          ldtx workspace select-youtube-livebroadcast <broadcast-id>|--none
          ldtx workspace program-select <name>|--scratch-pad
          ldtx workspace record-start|record-stop|record-split
          ldtx workspace start-output|stop-output
          ldtx workspace output-settings get|set
          ldtx workspace selected-program-name
        """
    )
  }

  static func failure(_ message: String) -> CLIError {
    CLIError(exitCode: 1, message: message)
  }
}

extension CLIError {
  fileprivate static let recordingUsage = CLIError(
    exitCode: 64,
    message: """
      Usage:
        ldtx record inspect <recording.ldtxrecord>
        ldtx record verify <recording.ldtxrecord> [--strict]
        ldtx record remux <recording.ldtxrecord> [--output <file.mp4>] [--replace] [--strict]
      """
  )
}

private struct RecordingInspectionValue: Encodable {
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
    audioTracks = package.audioTracks.map { track in
      AudioTrack(
        identifier: track.identifier,
        name: track.name,
        mediaFile: track.mediaPath,
        playlist: track.playlistPath
      )
    }
  }
}

private struct InputDevicesPayload: Encodable {
  var cameras: [InputCameraDevicePayload]
  var audioDevices: [InputAudioDevicePayload]
}

private struct InputCameraDevicePayload: Encodable {
  var id: String
  var name: String
  var deviceType: String
  var modelID: String
  var width: Int
  var height: Int
  var isExternal: Bool
  var formatSummary: String
  var linkedDeviceIDs: [String]

  init(_ source: CameraCaptureSource) {
    id = source.id
    name = source.name
    deviceType = source.deviceType
    modelID = source.modelID
    width = source.width
    height = source.height
    isExternal = source.isExternal
    formatSummary = source.formatSummary
    linkedDeviceIDs = source.linkedDeviceIDs
  }
}

private struct InputAudioDevicePayload: Encodable {
  var id: String
  var name: String
  var deviceType: String
  var modelID: String
  var isExternal: Bool
  var formatSummary: String
  var linkedDeviceIDs: [String]

  init(_ source: AudioCaptureSource) {
    id = source.id
    name = source.name
    deviceType = source.deviceType
    modelID = source.modelID
    isExternal = source.isExternal
    formatSummary = source.formatSummary
    linkedDeviceIDs = source.linkedDeviceIDs
  }
}

extension Ldtx_Automation_V1_InputDeviceRecord {
  fileprivate var workspaceRecord: WorkspaceInputDeviceRecord {
    WorkspaceInputDeviceRecord(
      name: name,
      kind: kind.workspaceValue,
      physicalDeviceID: physicalDeviceID.isEmpty ? nil : physicalDeviceID
    )
  }
}

extension Ldtx_Automation_V1_InputDeviceKind {
  fileprivate var workspaceValue: WorkspaceInputDeviceKind {
    switch self {
    case .unspecified, .UNRECOGNIZED(_):
      .unspecified
    case .video:
      .video
    case .audio:
      .audio
    }
  }
}
