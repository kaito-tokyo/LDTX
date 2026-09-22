// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import LDTXAppHelper
import LDTXUtils

@main
struct LDTXHelperCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ldtx",
    abstract:
      "Inspect, verify, and remux LDTX recording packages, or control the LDTX application.",
    subcommands: LdtxCLI.fileSubcommands + [
      AppAutomationCommand.self,
      AppAutomationMCPCommand.self,
    ]
  )

  mutating func run() async throws {}
}

private struct AppAutomationCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "app",
    abstract: "Control the LDTX application.")

  mutating func run() async throws {
    do {
      try EmptyAppAutomationService().execute(operation: "app")
    } catch {
      throw ValidationError(error.localizedDescription)
    }
  }
}

private struct AppAutomationMCPCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mcp",
    abstract: "Run the App Automation MCP server.")

  mutating func run() async throws {
    try await AppAutomationMCPServer().run()
  }
}
