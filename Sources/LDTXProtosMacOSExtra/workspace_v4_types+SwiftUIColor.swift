// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProtos
import SwiftUI

extension Ldtx_Workspace_V4_Color {
  /// Interprets RGBA components, including protobuf defaults, as extended sRGB for SwiftUI.
  public var extendedSRGBSwiftUIColor: SwiftUI.Color? {
    extendedSRGBNSColor.map { SwiftUI.Color(nsColor: $0) }
  }

  /// Converts a SwiftUI color to extended sRGB and sets all four components.
  public init?(extendedSRGBSwiftUIColor color: SwiftUI.Color) {
    self.init(extendedSRGBNSColor: NSColor(color))
  }
}
