// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCorelibs
import Security
import os

/// An in-memory stand-in for the data-protection and legacy keychains, for hostless tests that
/// have no Keychain entitlement.
final class FakeDataProtectionKeychain: Sendable {
  struct Key: Hashable {
    var dataProtection: Bool
    var service: String
    var account: String
  }

  struct Item: Equatable {
    var data: Data
    var accessibility: String?
  }

  private struct State {
    var items: [Key: Item] = [:]
    var failures: [String: OSStatus] = [:]
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  var items: [Key: Item] { state.withLock { $0.items } }

  func seed(_ key: Key, _ item: Item) { state.withLock { $0.items[key] = item } }

  /// Makes every call of `operation` ("copyMatching", "add", "update", or "delete") return `status`.
  func fail(_ operation: String, with status: OSStatus) {
    state.withLock { $0.failures[operation] = status }
  }

  var operations: DataProtectionKeychainItem.Operations {
    DataProtectionKeychainItem.Operations(
      copyMatching: { query, result in
        self.perform("copyMatching", query) { state, key, _ in
          guard let item = state.items[key] else { return errSecItemNotFound }
          result?.pointee = item.data as CFData
          return errSecSuccess
        }
      },
      add: { attributes, _ in
        self.perform("add", attributes) { state, key, values in
          guard state.items[key] == nil else { return errSecDuplicateItem }
          guard let data = values[kSecValueData as String] as? Data else { return errSecParam }
          state.items[key] = Item(
            data: data, accessibility: values[kSecAttrAccessible as String] as? String)
          return errSecSuccess
        }
      },
      update: { query, attributes in
        let changes = attributes as NSDictionary as? [String: Any] ?? [:]
        return self.perform("update", query) { state, key, _ in
          guard var item = state.items[key] else { return errSecItemNotFound }
          if let data = changes[kSecValueData as String] as? Data { item.data = data }
          if let accessibility = changes[kSecAttrAccessible as String] as? String {
            item.accessibility = accessibility
          }
          state.items[key] = item
          return errSecSuccess
        }
      },
      delete: { query in
        self.perform("delete", query) { state, key, _ in
          state.items.removeValue(forKey: key) == nil ? errSecItemNotFound : errSecSuccess
        }
      })
  }

  private func perform(
    _ operation: String, _ query: CFDictionary,
    _ body: (inout State, Key, [String: Any]) -> OSStatus
  ) -> OSStatus {
    let values = query as NSDictionary as? [String: Any] ?? [:]
    guard
      let service = values[kSecAttrService as String] as? String,
      let account = values[kSecAttrAccount as String] as? String,
      let dataProtection = values[kSecUseDataProtectionKeychain as String] as? Bool
    else { return errSecParam }
    let key = Key(dataProtection: dataProtection, service: service, account: account)
    // The body and the decoded query never leave this synchronous call.
    return state.withLockUnchecked { state in
      if let status = state.failures[operation] { return status }
      return body(&state, key, values)
    }
  }
}
