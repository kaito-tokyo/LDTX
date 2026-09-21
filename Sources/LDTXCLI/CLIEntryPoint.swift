// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import LDTXHelper

@main
struct LDTXHelperCommand: AsyncParsableCommand {
  static let configuration = LDTXHelper.configuration

  mutating func run() async throws {}
}
