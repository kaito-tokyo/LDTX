// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

public enum OAuthClientConfigurationStoreError: Error, Equatable, LocalizedError {
    case decodingFailed
    case keychainFailure(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .decodingFailed:
            "The stored OAuth client JSON could not be decoded."
        case let .keychainFailure(status):
            "The Keychain operation failed with status \(status)."
        }
    }
}

public struct OAuthClientConfigurationStore {
    private let service: String
    private let account: String

    public init(
        service: String = "tokyo.kaito.ldtx.oauth-client",
        account: String = "google-oauth-client-json"
    ) {
        self.service = service
        self.account = account
    }

    public func load() throws -> GoogleOAuthClientConfiguration? {
        guard let keychainData = try loadFromKeychain() else {
            return nil
        }
        return try decode(keychainData)
    }

    public func save(_ data: Data) throws {
        _ = try decode(data)
        try saveToKeychain(data)
    }

    public func delete() throws {
        try deleteFromKeychain()
    }

    private func decode(_ data: Data) throws -> GoogleOAuthClientConfiguration {
        do {
            return try GoogleOAuthClientConfiguration(data: data)
        } catch {
            throw OAuthClientConfigurationStoreError.decodingFailed
        }
    }

    private func loadFromKeychain() throws -> Data? {
        var query = keychainQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw OAuthClientConfigurationStoreError.keychainFailure(status)
        }
        return item as? Data
    }

    private func saveToKeychain(_ data: Data) throws {
        let query = keychainQuery
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw OAuthClientConfigurationStoreError.keychainFailure(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw OAuthClientConfigurationStoreError.keychainFailure(addStatus)
        }
    }

    private func deleteFromKeychain() throws {
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OAuthClientConfigurationStoreError.keychainFailure(status)
        }
    }

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
