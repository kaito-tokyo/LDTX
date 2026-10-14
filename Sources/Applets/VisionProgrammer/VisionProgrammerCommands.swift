// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

public struct VisionProgrammerCommands: Commands {
  @Environment(\.openWindow) private var openWindow

  public init() {}

  public var body: some Commands {
    CommandGroup(after: .appSettings) {
      Button("Vision Programmer…") { openWindow(id: VisionProgrammerScene.id) }
    }
  }
}
