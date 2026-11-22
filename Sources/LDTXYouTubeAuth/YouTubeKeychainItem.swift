// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

/// One generic-password item of the YouTube authentication stores.
///
/// Items live in the data-protection keychain, in the app's default access group (the first
/// `keychain-access-groups` entitlement), and are readable only after the first unlock on this
/// device. Both new and existing items receive that accessibility on every save.
///
/// Earlier versions wrote these items to the legacy file-based keychain, where the accessibility
/// attribute has no effect. Those items are not migrated. When the data-protection item is missing
/// or deleted, the legacy item with the same service and account is deleted as well, so the user
/// loads the OAuth client and authorizes again instead of leaving refresh tokens behind.
struct YouTubeKeychainItem {
  struct StatusError: Error, Equatable {
    var status: OSStatus
  }

  /// The Security calls used by the item, replaceable in tests that run without entitlements.
  struct Operations: Sendable {
    var copyMatching: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    var add: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    var update: @Sendable (CFDictionary, CFDictionary) -> OSStatus
    var delete: @Sendable (CFDictionary) -> OSStatus

    static let system = Operations(
      copyMatching: SecItemCopyMatching, add: SecItemAdd, update: SecItemUpdate,
      delete: SecItemDelete)
  }

  static var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

  let service: String
  let account: String
  let operations: Operations

  func load() throws -> Data? {
    var query = query(dataProtection: true)
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecReturnData as String] = true

    var item: CFTypeRef?
    let status = operations.copyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      deleteLegacyItem()
      return nil
    }
    guard status == errSecSuccess else { throw StatusError(status: status) }
    return item as? Data
  }

  func save(_ data: Data) throws {
    let query = query(dataProtection: true)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: Self.accessibility,
    ]
    let updateStatus = operations.update(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else { throw StatusError(status: updateStatus) }

    let item = query.merging(attributes) { _, new in new }
    let addStatus = operations.add(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw StatusError(status: addStatus) }
  }

  func delete() throws {
    let status = operations.delete(query(dataProtection: true) as CFDictionary)
    deleteLegacyItem()
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw StatusError(status: status)
    }
  }

  /// Best-effort removal of the item an earlier version wrote to the legacy keychain. A failure
  /// leaves only an unused legacy item behind, so it does not fail the caller.
  private func deleteLegacyItem() {
    _ = operations.delete(query(dataProtection: false) as CFDictionary)
  }

  private func query(dataProtection: Bool) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecUseDataProtectionKeychain as String: dataProtection,
    ]
  }
}
