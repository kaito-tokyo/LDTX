// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXYouTubeRTMPS
import Security

struct YouTubeStreamKeyConfigurationStore {
  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "tokyo.kaito.ldtx.youtube-stream-keys",
      kSecAttrAccount as String: "configurations",
    ]
  }

  func load() throws -> [YouTubeRTMPSStreamKeyConfiguration] {
    var query = query
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess, let data = item as? Data else { throw StoreError.loadFailed }
    do {
      return try JSONDecoder().decode([YouTubeRTMPSStreamKeyConfiguration].self, from: data)
    } catch { throw StoreError.loadFailed }
  }

  func save(_ configurations: [YouTubeRTMPSStreamKeyConfiguration]) throws {
    for configuration in configurations { _ = try configuration.destination() }
    guard Set(configurations.map(\.id)).count == configurations.count else {
      throw StoreError.saveFailed
    }
    let data = try JSONEncoder().encode(configurations)
    let status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw StoreError.saveFailed }
    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
      throw StoreError.saveFailed
    }
  }

  enum StoreError: Error, LocalizedError {
    case loadFailed, saveFailed
    var errorDescription: String? {
      switch self {
      case .loadFailed: "Stream key configurations could not be loaded from Keychain."
      case .saveFailed: "Stream key configurations could not be saved to Keychain."
      }
    }
  }
}
