// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AppAuth
import Foundation
import Security

enum YouTubeAuthorizationStoreError: Error, Equatable, LocalizedError {
    case encodingFailed
    case decodingFailed
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            "The YouTube authorization state could not be encoded for storage."
        case .decodingFailed:
            "The stored YouTube authorization state could not be decoded."
        case let .keychainFailure(status):
            "The Keychain operation failed with status \(status)."
        }
    }
}

struct YouTubeAuthorizationStore {
    private let service: String

    init(service: String = "tokyo.kaito.ldtx.youtube-auth") {
        self.service = service
    }

    func load(clientID: String) throws -> OIDAuthState? {
        guard let keychainData = try loadFromKeychain(clientID: clientID) else {
            return nil
        }
        return try decode(keychainData)
    }

    func save(_ authState: OIDAuthState, clientID: String) throws {
        let data = try encode(authState)
        try saveToKeychain(data, clientID: clientID)
    }

    func delete(clientID: String) throws {
        try deleteFromKeychain(clientID: clientID)
    }

    private func encode(_ authState: OIDAuthState) throws -> Data {
        do {
            return try NSKeyedArchiver.archivedData(withRootObject: authState, requiringSecureCoding: true)
        } catch {
            throw YouTubeAuthorizationStoreError.encodingFailed
        }
    }

    private func decode(_ data: Data) throws -> OIDAuthState {
        do {
            guard let authState = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data) else {
                throw YouTubeAuthorizationStoreError.decodingFailed
            }
            return authState
        } catch let error as YouTubeAuthorizationStoreError {
            throw error
        } catch {
            throw YouTubeAuthorizationStoreError.decodingFailed
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
            throw YouTubeAuthorizationStoreError.keychainFailure(status)
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
            throw YouTubeAuthorizationStoreError.keychainFailure(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw YouTubeAuthorizationStoreError.keychainFailure(addStatus)
        }
    }

    private func deleteFromKeychain(clientID: String) throws {
        let status = SecItemDelete(keychainQuery(clientID: clientID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw YouTubeAuthorizationStoreError.keychainFailure(status)
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
