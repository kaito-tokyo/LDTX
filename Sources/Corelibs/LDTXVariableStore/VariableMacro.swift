// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum VariableMacro {
  public static func token(for key: VariableKey) -> String { "{{\(key.path)}}" }

  /// Single-pass expansion preserves malformed tokens and treats values as literal text.
  public static func expand(_ text: String, using store: VariableStore) -> String {
    var remaining = text[...]
    var result = ""
    while let start = remaining.range(of: "{{") {
      result += remaining[..<start.lowerBound]
      guard let end = remaining[start.upperBound...].range(of: "}}") else {
        result += remaining[start.lowerBound...]
        return result
      }
      let path = String(remaining[start.upperBound..<end.lowerBound])
      if let key = try? VariableKey(path: path) {
        result += (try? store.read(key)) ?? ""
      } else {
        result += remaining[start.lowerBound..<end.upperBound]
      }
      remaining = remaining[end.upperBound...]
    }
    return result + remaining
  }
}
