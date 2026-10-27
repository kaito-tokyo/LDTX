// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import LDTXAppHelper
import LDTXUtils

@main
struct LDTXHelperCommand {
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    do {
      if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
        print("Usage: ldtx <workspace|record|app|mcp> …")
        return
      }
      switch arguments[0] {
      case "app":
        guard arguments.count == 1 else { throw CLIValidationError("app takes no arguments.") }
        try EmptyAppAutomationService().execute(operation: "app")
      case "mcp":
        guard arguments.count == 1 else { throw CLIValidationError("mcp takes no arguments.") }
        try await AppAutomationMCPServer().run()
      default:
        try await LdtxCLI.run(arguments: arguments)
      }
    } catch {
      FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }
}
