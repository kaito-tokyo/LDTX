// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#if os(Linux)
  import FoundationEssentials
#else
  import Foundation
#endif

public struct ClockOutlineColor: Equatable, Sendable {
  public var red: Float
  public var green: Float
  public var blue: Float
  public var alpha: Float

  public init(red: Float, green: Float, blue: Float, alpha: Float) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  public static let clear = ClockOutlineColor(red: 0, green: 0, blue: 0, alpha: 0)
}

extension ClockOutlineColor {
  public static func parse(_ source: String) -> ClockOutlineColor? {
    let value = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value == "transparent" { return .clear }
    if value.hasPrefix("#") { return parseHex(String(value.dropFirst())) }
    if value.hasPrefix("rgb(") || value.hasPrefix("rgba(") {
      guard let open = value.firstIndex(of: "("), value.hasSuffix(")") else { return nil }
      let body = value[value.index(after: open)..<value.index(before: value.endIndex)]
      let normalized = body.replacingOccurrences(of: ",", with: " ")
      let parts = normalized.split(whereSeparator: { $0 == " " || $0 == "/" })
      guard parts.count == 3 || parts.count == 4,
        let red = Float(parts[0]),
        let green = Float(parts[1]),
        let blue = Float(parts[2])
      else {
        return nil
      }
      let alpha = parts.count == 4 ? Float(parts[3]) : 1
      guard let alpha,
        (0...255).contains(red),
        (0...255).contains(green),
        (0...255).contains(blue),
        (0...1).contains(alpha)
      else {
        return nil
      }
      return ClockOutlineColor(
        red: red / 255,
        green: green / 255,
        blue: blue / 255,
        alpha: alpha
      )
    }
    return nil
  }

  private static func parseHex(_ value: String) -> ClockOutlineColor? {
    let expanded: String
    switch value.count {
    case 3, 4:
      expanded = value.map { "\($0)\($0)" }.joined()
    case 6, 8:
      expanded = value
    default:
      return nil
    }
    guard let integer = UInt64(expanded, radix: 16) else { return nil }
    let hasAlpha = expanded.count == 8
    return ClockOutlineColor(
      red: Float((integer >> (hasAlpha ? 24 : 16)) & 0xff) / 255,
      green: Float((integer >> (hasAlpha ? 16 : 8)) & 0xff) / 255,
      blue: Float((integer >> (hasAlpha ? 8 : 0)) & 0xff) / 255,
      alpha: hasAlpha ? Float(integer & 0xff) / 255 : 1
    )
  }
}
