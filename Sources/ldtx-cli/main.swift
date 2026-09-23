// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import LDTXUtils

@main
struct LDTXCommand: AsyncParsableCommand {
  static let configuration = LdtxCLI.configuration

  mutating func run() async throws {}
}
