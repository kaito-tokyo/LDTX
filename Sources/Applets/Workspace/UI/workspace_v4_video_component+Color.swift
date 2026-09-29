// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import SwiftUI

extension Ldtx_Workspace_V4_ExtendedSrgbColor {
  func asColor() -> Color {
    Color(
      .sRGB,
      red: Double(self.red),
      green: Double(self.green),
      blue: Double(self.blue),
      opacity: Double(self.alpha))
  }
}
