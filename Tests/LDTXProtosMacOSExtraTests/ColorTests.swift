// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProtos
import LDTXProtosMacOSExtra
import SwiftUI
import Testing

@Suite
struct ExtendedSRGBColorUnitTestSuite {
  @Test(arguments: [0, 1, 2, 3])
  func rejectsMissingComponents(component: Int) {
    var color = Ldtx_Workspace_V4_Color.with {
      $0.red = 0
      $0.green = 0
      $0.blue = 0
      $0.alpha = 0
    }
    switch component {
    case 0: color.clearRed()
    case 1: color.clearGreen()
    case 2: color.clearBlue()
    default: color.clearAlpha()
    }
    #expect(color.extendedSRGBNSColor == nil)
    #expect(color.extendedSRGBSwiftUIColor == nil)
  }

  @Test func preservesExplicitZeroAndExtendedComponents() throws {
    let source = Ldtx_Workspace_V4_Color.with {
      $0.red = -0.25
      $0.green = 1.5
      $0.blue = 0
      $0.alpha = 0
    }
    let nsColor = try #require(source.extendedSRGBNSColor)
    #expect(nsColor.colorSpace == .extendedSRGB)
    let restored = try #require(Ldtx_Workspace_V4_Color(extendedSRGBNSColor: nsColor))
    #expect(restored.hasRed && restored.hasGreen && restored.hasBlue && restored.hasAlpha)
    #expect(restored.red == source.red)
    #expect(restored.green == source.green)
    #expect(restored.blue == 0)
    #expect(restored.alpha == 0)
  }

  @Test func convertsOtherColorSpaces() throws {
    let source = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.8)
    let value = try #require(Ldtx_Workspace_V4_Color(extendedSRGBNSColor: source))
    #expect(abs(value.red - 0.2) < 0.00001)
    #expect(abs(value.green - 0.4) < 0.00001)
    #expect(abs(value.blue - 0.6) < 0.00001)
    #expect(abs(value.alpha - 0.8) < 0.00001)
  }
  @Test func swiftUIBridgeUsesExtendedSRGB() throws {
    let source = Ldtx_Workspace_V4_Color.with {
      $0.red = -0.25
      $0.green = 1.5
      $0.blue = 0.3
      $0.alpha = 0.8
    }
    let color = try #require(source.extendedSRGBSwiftUIColor)
    let restored = try #require(Ldtx_Workspace_V4_Color(extendedSRGBSwiftUIColor: color))
    #expect(abs(restored.red - source.red) < 0.00001)
    #expect(abs(restored.green - source.green) < 0.00001)
    #expect(abs(restored.blue - source.blue) < 0.00001)
    #expect(abs(restored.alpha - source.alpha) < 0.00001)
  }

}
