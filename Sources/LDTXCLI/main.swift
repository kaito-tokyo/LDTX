// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import LDTXAutomation

@main
struct LDTXCLI {
    private static let appBundleIdentifier = "tokyo.kaito.ldtx.LDTX"

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
        case "launch":
            try launchApp()
        case "terminate":
            try printCommandResult(sendCommand(method: LDTXAutomationMethod.appTerminate))
        case "program-select":
            try programSelect(arguments: rest)
        case "record-start":
            try printCommandResult(sendCommand(method: LDTXAutomationMethod.recordStart))
        case "record-stop":
            try printCommandResult(sendCommand(method: LDTXAutomationMethod.recordStop))
        case "output-settings":
            try outputSettings(arguments: rest)
        case "selected-program-name":
            try printSelectedProgramName()
        default:
            throw CLIError.usage
        }
    }

    private static func launchApp() throws {
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleIdentifier)
            ?? URL(fileURLWithPath: "/Applications/LDTX.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw CLIError.failure("LDTX.app was not found.")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        let semaphore = DispatchSemaphore(value: 0)
        let launchResult = LaunchResult()
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            launchResult.error = error
            semaphore.signal()
        }
        semaphore.wait()

        if let launchError = launchResult.error {
            throw launchError
        }
        print("Launched LDTX.")
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
              ldtx launch
              ldtx terminate
              ldtx program-select <name>
              ldtx program-select --scratch-pad
              ldtx record-start
              ldtx record-stop
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

private final class LaunchResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
        get {
            lock.withLock {
                storedError
            }
        }
        set {
            lock.withLock {
                storedError = newValue
            }
        }
    }
}
