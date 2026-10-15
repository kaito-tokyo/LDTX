// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXVisionProgrammerApplet
import SwiftUI

@main
struct LDTXVisionProgrammerApp: App {
  var body: some Scene {
    Window("Vision Programmer", id: VisionProgrammerView.id) {
      VisionProgrammerView()
    }
    .defaultSize(width: 700, height: 500)
    .windowToolbarStyle(.unified)
  }
}
