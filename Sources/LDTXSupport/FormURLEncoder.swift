// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum FormURLEncoder {
    public static func encode(_ fields: [(String, String?)]) -> Data {
        let body = fields.compactMap { key, value -> String? in
            guard let value else { return nil }
            return "\(escape(key))=\(escape(value))"
        }
        .joined(separator: "&")

        return Data(body.utf8)
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
