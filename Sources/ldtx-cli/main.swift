// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import LDTXUtils

@main
struct LDTXCommand {
  static func main() async {
    do {
      try await LdtxCLI.run()
    } catch {
      FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }
}
