// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftProtobuf

public extension SwiftProtobuf.Message {
    func jsonRPCValue() throws -> JSONValue {
        let data = try jsonUTF8Data()
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    init(jsonRPCValue: JSONValue) throws {
        let data = try JSONEncoder().encode(jsonRPCValue)
        try self.init(jsonUTF8Bytes: data)
    }
}
