// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct ClockCSSColor: Equatable, Sendable {
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

    public static let clear = ClockCSSColor(red: 0, green: 0, blue: 0, alpha: 0)
}

public enum ClockCSSBackground: Equatable, Sendable {
    case solid(ClockCSSColor)
    case linearGradient(
        angleDegrees: Float,
        startColor: ClockCSSColor,
        endColor: ClockCSSColor
    )

    /// Parses the CSS subset supported by Clock. An empty value means a
    /// transparent background. Unsupported or malformed values return nil.
    public static func parse(_ source: String) -> Self? {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return .solid(.clear) }
        if let color = parseColor(value) { return .solid(color) }
        guard value.lowercased().hasPrefix("linear-gradient("), value.hasSuffix(")") else {
            return nil
        }
        let start = value.index(value.startIndex, offsetBy: "linear-gradient(".count)
        let body = String(value[start..<value.index(before: value.endIndex)])
        let fields = topLevelCommaSeparated(body)
        guard fields.count == 3,
              fields[0].lowercased().hasSuffix("deg"),
              let degrees = Float(fields[0].dropLast(3).trimmingCharacters(in: .whitespaces)),
              degrees.isFinite,
              let startColor = parseColor(fields[1]),
              let endColor = parseColor(fields[2]) else {
            return nil
        }
        return .linearGradient(
            angleDegrees: degrees,
            startColor: startColor,
            endColor: endColor
        )
    }

    public static func isValid(_ source: String) -> Bool {
        parse(source) != nil
    }

    public static func parseColor(_ source: String) -> ClockCSSColor? {
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
                  let blue = Float(parts[2]) else {
                return nil
            }
            let alpha = parts.count == 4 ? Float(parts[3]) : 1
            guard let alpha,
                  (0...255).contains(red),
                  (0...255).contains(green),
                  (0...255).contains(blue),
                  (0...1).contains(alpha) else {
                return nil
            }
            return ClockCSSColor(
                red: red / 255,
                green: green / 255,
                blue: blue / 255,
                alpha: alpha
            )
        }
        return nil
    }

    private static func topLevelCommaSeparated(_ value: String) -> [String] {
        var depth = 0
        var current = ""
        var result: [String] = []
        for character in value {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if character == ",", depth == 0 {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    private static func parseHex(_ value: String) -> ClockCSSColor? {
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
        return ClockCSSColor(
            red: Float((integer >> (hasAlpha ? 24 : 16)) & 0xff) / 255,
            green: Float((integer >> (hasAlpha ? 16 : 8)) & 0xff) / 255,
            blue: Float((integer >> (hasAlpha ? 8 : 0)) & 0xff) / 255,
            alpha: hasAlpha ? Float(integer & 0xff) / 255 : 1
        )
    }
}
