// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import LDTXSupport
import Security

public enum PKCE {
    public static func makeVerifier(byteCount: Int = 32) throws -> String {
        precondition(byteCount >= 32)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw PKCEError.randomGenerationFailed(status)
        }
        return Data(bytes).base64URLEncodedString()
    }

    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

public enum PKCEError: Error, Equatable, LocalizedError {
    case randomGenerationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .randomGenerationFailed(status):
            "Failed to generate a PKCE verifier; OSStatus \(status)."
        }
    }
}
