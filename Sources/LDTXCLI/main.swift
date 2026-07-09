// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXAutomation
import LDTXCapture
import LDTXWorkspace

@main
struct LDTXCLI {
    static func main() {
        do {
            try run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch let error as CLIError {
            fputs("ldtx: \(error.message)\n", stderr)
            exit(Int32(error.exitCode))
        } catch {
            fputs("ldtx: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            throw CLIError.usage
        }

        let rest = Array(arguments.dropFirst())
        switch command {
        case "input-devices", "print-input-devices":
            try printInputDevices()
        case "get-input-devices":
            try printWorkspaceInputDevices()
        case "select-input-device":
            try selectInputDevice(arguments: rest)
        case "select-youtube-livebroadcast":
            try selectYouTubeLiveBroadcast(arguments: rest)
        case "get-program":
            try printActiveProgramDefinition()
        case "program-select":
            try programSelect(arguments: rest)
        case "record-start":
            try printCommandResult(sendCommand(method: LDTXAutomationMethod.recordStart))
        case "record-stop":
            try printCommandResult(sendCommand(method: LDTXAutomationMethod.recordStop))
        case "record-split":
            try printCommandResult(sendCommand(method: LDTXAutomationMethod.recordSplit))
        case "start-output":
            try printCommandResult(sendCommand(method: LDTXAutomationMethod.outputStart))
        case "stop-output":
            try printCommandResult(sendCommand(method: LDTXAutomationMethod.outputStop))
        case "output-settings":
            try outputSettings(arguments: rest)
        case "selected-program-name":
            try printSelectedProgramName()
        default:
            throw CLIError.usage
        }
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

    private static func printWorkspaceInputDevices() throws {
        let response = try sendRequest(JSONRPCRequest(
            id: .string(UUID().uuidString),
            method: LDTXAutomationMethod.inputDevicesGet
        ))
        let result = try responseResult(response)
        let inputDevices = try Ldtx_Automation_V1_InputDevicesResult(jsonRPCValue: result)
        let payload = inputDevices.inputDevices.map(\.workspaceRecord)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func selectInputDevice(arguments: [String]) throws {
        guard let workspaceInputDeviceID = arguments.first else {
            throw CLIError.failure(
                "Usage: ldtx select-input-device <workspace-input-device-id> <physical-device-id>|--none"
            )
        }
        let rest = Array(arguments.dropFirst())
        guard rest.count == 1 else {
            throw CLIError.failure(
                "Usage: ldtx select-input-device <workspace-input-device-id> <physical-device-id>|--none"
            )
        }

        var params = Ldtx_Automation_V1_InputDeviceSelectParams()
        params.workspaceInputDeviceID = workspaceInputDeviceID
        if rest[0] != "--none" {
            let physicalDeviceID = rest[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !physicalDeviceID.isEmpty else {
                throw CLIError.failure("Physical device ID must not be empty.")
            }
            params.physicalDeviceID = physicalDeviceID
        }

        try printCommandResult(sendCommand(
            method: LDTXAutomationMethod.inputDeviceSelect,
            params: params.jsonRPCValue()
        ))
    }

    private static func selectYouTubeLiveBroadcast(arguments: [String]) throws {
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

        try printCommandResult(sendCommand(
            method: LDTXAutomationMethod.outputSettingsSet,
            params: settings.jsonRPCValue()
        ))
    }

    private static func programSelect(arguments: [String]) throws {
        let isScratchPad = arguments == ["--scratch-pad"]
        let name = isScratchPad ? "" : arguments.joined(separator: " ")
        guard isScratchPad || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.failure("Usage: ldtx program-select <name>|--scratch-pad")
        }

        var params = Ldtx_Automation_V1_ProgramSelectParams()
        params.name = name
        params.isScratchPad = isScratchPad
        try printCommandResult(sendCommand(
            method: LDTXAutomationMethod.programSelect,
            params: params.jsonRPCValue()
        ))
    }

    private static func printActiveProgramDefinition() throws {
        let response = try sendRequest(JSONRPCRequest(
            id: .string(UUID().uuidString),
            method: LDTXAutomationMethod.programGet
        ))
        let result = try responseResult(response)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(result)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func printSelectedProgramName() throws {
        let response = try sendRequest(JSONRPCRequest(
            id: .string(UUID().uuidString),
            method: LDTXAutomationMethod.selectedProgramName
        ))
        let result = try responseResult(response)
        let selectedProgram = try Ldtx_Automation_V1_SelectedProgramNameResult(jsonRPCValue: result)
        print(selectedProgram.name)
    }

    private static func outputSettings(arguments: [String]) throws {
        guard let subcommand = arguments.first else {
            throw CLIError.failure("Usage: ldtx output-settings get|set <json>|set --file <path>|set -")
        }

        switch subcommand {
        case "get":
            guard arguments.count == 1 else {
                throw CLIError.failure("Usage: ldtx output-settings get")
            }
            try printOutputSettings()
        case "set":
            let settings = try outputSettingsFromJSONArguments(Array(arguments.dropFirst()))
            try printCommandResult(sendCommand(
                method: LDTXAutomationMethod.outputSettingsSet,
                params: settings.jsonRPCValue()
            ))
        default:
            throw CLIError.failure("Usage: ldtx output-settings get|set <json>|set --file <path>|set -")
        }
    }

    private static func printOutputSettings() throws {
        let response = try sendRequest(JSONRPCRequest(
            id: .string(UUID().uuidString),
            method: LDTXAutomationMethod.outputSettingsGet
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
            throw CLIError.failure("Output Settings JSON could not be parsed: \(error.localizedDescription)")
        }
    }

    private static func sendCommand(method: String, params: JSONValue? = nil) throws -> Ldtx_Automation_V1_CommandResult {
        let response = try sendRequest(JSONRPCRequest(
            id: .string(UUID().uuidString),
            method: method,
            params: params
        ))
        let result = try responseResult(response)
        return try Ldtx_Automation_V1_CommandResult(jsonRPCValue: result)
    }

    private static func sendRequest(_ request: JSONRPCRequest) throws -> JSONRPCResponse {
        let response = try LDTXBrokerClient.send(request)
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
            throw CLIError(exitCode: 1, message: result.message.isEmpty ? "Command failed." : result.message)
        }
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
              ldtx get-input-devices
              ldtx get-program
              ldtx print-input-devices
              ldtx input-devices
              ldtx select-input-device <workspace-input-device-id> <physical-device-id>
              ldtx select-input-device <workspace-input-device-id> --none
              ldtx select-youtube-livebroadcast <broadcast-id>
              ldtx select-youtube-livebroadcast --none
              ldtx program-select <name>
              ldtx program-select --scratch-pad
              ldtx record-start
              ldtx record-stop
              ldtx record-split
              ldtx start-output
              ldtx stop-output
              ldtx output-settings get
              ldtx output-settings set <json>
              ldtx output-settings set --file <path>
              ldtx output-settings set -
              ldtx selected-program-name
            """
        )
    }

    static func failure(_ message: String) -> CLIError {
        CLIError(exitCode: 1, message: message)
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

private extension Ldtx_Automation_V1_InputDeviceRecord {
    var workspaceRecord: WorkspaceInputDeviceRecord {
        WorkspaceInputDeviceRecord(
            id: id,
            name: name,
            kind: kind.workspaceValue,
            physicalDeviceID: physicalDeviceID.isEmpty ? nil : physicalDeviceID,
            sideTrackRecordingPolicy: sideTrackRecordingPolicy.workspaceValue
        )
    }
}

private extension Ldtx_Automation_V1_InputDeviceKind {
    var workspaceValue: WorkspaceInputDeviceKind {
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

private extension Ldtx_Automation_V1_SideTrackRecordingPolicy {
    var workspaceValue: WorkspaceSideTrackRecordingPolicy {
        switch self {
        case .unspecified, .UNRECOGNIZED(_):
            .unspecified
        case .enabled:
            .enabled
        case .disabled:
            .disabled
        }
    }
}
