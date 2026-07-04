// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

public struct StoredOAuthToken: Codable, Equatable, Sendable {
    public var response: OAuthTokenResponse
    public var issuedAt: Date

    public init(response: OAuthTokenResponse, issuedAt: Date = Date()) {
        self.response = response
        self.issuedAt = issuedAt
    }

    public var refreshToken: String? {
        response.refreshToken
    }

    public func isAccessTokenValid(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let expiresIn = response.expiresIn else {
            return !response.accessToken.isEmpty
        }
        return issuedAt.addingTimeInterval(TimeInterval(expiresIn) - leeway) > now
    }

    public func replacingResponseAfterRefresh(_ refreshed: OAuthTokenResponse, issuedAt: Date = Date()) -> StoredOAuthToken {
        var response = refreshed
        if response.refreshToken == nil {
            response.refreshToken = self.response.refreshToken
        }
        return StoredOAuthToken(response: response, issuedAt: issuedAt)
    }
}

public enum OAuthTokenStoreError: Error, Equatable, LocalizedError {
    case encodingFailed
    case decodingFailed
    case keychainFailure(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            "The OAuth token could not be encoded for storage."
        case .decodingFailed:
            "The stored OAuth token could not be decoded."
        case let .keychainFailure(status):
            "The Keychain operation failed with status \(status)."
        }
    }
}

public protocol OAuthTokenStoring: Sendable {
    func load(clientID: String) throws -> StoredOAuthToken?
    func save(_ token: StoredOAuthToken, clientID: String) throws
    func delete(clientID: String) throws
}

public struct OAuthTokenStore: OAuthTokenStoring, @unchecked Sendable {
    private let service: String

    public init(
        service: String = "tokyo.kaito.ldtx.oauth"
    ) {
        self.service = service
    }

    public func load(clientID: String) throws -> StoredOAuthToken? {
        guard let keychainData = try loadFromKeychain(clientID: clientID) else {
            return nil
        }
        return try decode(keychainData)
    }

    public func save(_ token: StoredOAuthToken, clientID: String) throws {
        let data = try encode(token)
        try saveToKeychain(data, clientID: clientID)
    }

    public func delete(clientID: String) throws {
        try deleteFromKeychain(clientID: clientID)
    }

    private func encode(_ token: StoredOAuthToken) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(token)
        } catch {
            throw OAuthTokenStoreError.encodingFailed
        }
    }

    private func decode(_ data: Data) throws -> StoredOAuthToken {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(StoredOAuthToken.self, from: data)
        } catch {
            throw OAuthTokenStoreError.decodingFailed
        }
    }

    private func loadFromKeychain(clientID: String) throws -> Data? {
        var query = keychainQuery(clientID: clientID)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw OAuthTokenStoreError.keychainFailure(status)
        }
        return item as? Data
    }

    private func saveToKeychain(_ data: Data, clientID: String) throws {
        let query = keychainQuery(clientID: clientID)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw OAuthTokenStoreError.keychainFailure(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw OAuthTokenStoreError.keychainFailure(addStatus)
        }
    }

    private func deleteFromKeychain(clientID: String) throws {
        let status = SecItemDelete(keychainQuery(clientID: clientID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OAuthTokenStoreError.keychainFailure(status)
        }
    }

    private func keychainQuery(clientID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: clientID
        ]
    }
}
