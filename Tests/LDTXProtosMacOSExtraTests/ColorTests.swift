// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXCorelibs
import LDTXProtosMacOSExtra
import SwiftUI
import Testing

@Suite(.tags(.medium))
struct ExtendedSRGBColorUnitTestSuite {
  @Test("LUB-1004: Uses defaults for missing components", arguments: [0, 1, 2, 3])
  func usesDefaultsForMissingComponents(component: Int) throws {
    var color = Ldtx_Workspace_V4_Color.with {
      $0.red = 0
      $0.green = 0
      $0.blue = 0
      $0.alpha = 0
    }
    switch component {
    case 0: color.red = nil
    case 1: color.green = nil
    case 2: color.blue = nil
    default: color.alpha = nil
    }
    let converted = try #require(color.extendedSRGBNSColor)
    #expect(converted.redComponent == 0)
    #expect(converted.greenComponent == 0)
    #expect(converted.blueComponent == 0)
    #expect(converted.alphaComponent == 0)
    #expect(color.extendedSRGBSwiftUIColor != nil)
  }

  @Test("LUB-1004: Uses defaults for opaque black") func usesDefaultsForOpaqueBlack() throws {
    let color = Ldtx_Workspace_V4_Color.with { $0.alpha = 1 }
    let converted = try #require(color.extendedSRGBNSColor)
    #expect(
      converted.redComponent == 0 && converted.greenComponent == 0 && converted.blueComponent == 0)
    #expect(converted.alphaComponent == 1)
    #expect((color.red == nil) && (color.green == nil) && (color.blue == nil))
  }

  @Test("LUB-1004: Preserves explicit zero and extended components")
  func preservesExplicitZeroAndExtendedComponents() throws {
    let source = Ldtx_Workspace_V4_Color.with {
      $0.red = -0.25
      $0.green = 1.5
      $0.blue = 0
      $0.alpha = 0
    }
    let nsColor = try #require(source.extendedSRGBNSColor)
    #expect(nsColor.colorSpace == .extendedSRGB)
    let restored = try #require(Ldtx_Workspace_V4_Color(extendedSRGBNSColor: nsColor))
    #expect(
      (restored.red != nil) && (restored.green != nil) && (restored.blue != nil)
        && (restored.alpha != nil))
    #expect(restored.red == source.red)
    #expect(restored.green == source.green)
    #expect(restored.blue == 0)
    #expect(restored.alpha == 0)
  }

  @Test("LUB-1004: Converts other color spaces") func convertsOtherColorSpaces() throws {
    let source = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.8)
    let value = try #require(Ldtx_Workspace_V4_Color(extendedSRGBNSColor: source))
    #expect(abs(try #require(value.red) - 0.2) < 0.00001)
    #expect(abs(try #require(value.green) - 0.4) < 0.00001)
    #expect(abs(try #require(value.blue) - 0.6) < 0.00001)
    #expect(abs(try #require(value.alpha) - 0.8) < 0.00001)
  }
  @Test("LUB-1004: Swift UI bridge uses extended srgb") func swiftUIBridgeUsesExtendedSRGB() throws
  {
    let source = Ldtx_Workspace_V4_Color.with {
      $0.red = -0.25
      $0.green = 1.5
      $0.blue = 0.3
      $0.alpha = 0.8
    }
    let color = try #require(source.extendedSRGBSwiftUIColor)
    let restored = try #require(Ldtx_Workspace_V4_Color(extendedSRGBSwiftUIColor: color))
    #expect(abs(try #require(restored.red) - (#require(source.red))) < 0.00001)
    #expect(abs(try #require(restored.green) - (#require(source.green))) < 0.00001)
    #expect(abs(try #require(restored.blue) - (#require(source.blue))) < 0.00001)
    #expect(abs(try #require(restored.alpha) - (#require(source.alpha))) < 0.00001)
  }

}
