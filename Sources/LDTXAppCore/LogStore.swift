// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct LogStore {
    private(set) var text = ""

    mutating func append(_ message: String) {
        let timestamp = Self.timestamp()
        let timestampedMessage = message
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "[\(timestamp)] \($0)" }
            .joined(separator: "\n")

        if text.isEmpty {
            text = timestampedMessage
        } else {
            text += "\n\(timestampedMessage)"
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
