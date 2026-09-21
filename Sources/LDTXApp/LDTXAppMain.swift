// SPDX-FileCopyrightText: 2026 Kaito Udagawa
//
// SPDX-License-Identifier: Apache-2.0

import AppKit

@main
@MainActor
struct LDTXAppMain {
  private static let delegate = AppDelegate()
  
  static func main() {
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
  }
}
