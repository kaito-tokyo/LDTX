//
//  workspace_v4_video_component+Color.swift
//  LDTX
//
//  Created by umireon on 2026/09/27.
//

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
