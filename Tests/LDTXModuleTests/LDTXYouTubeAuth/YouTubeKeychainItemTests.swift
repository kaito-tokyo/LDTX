// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import LDTXYouTubeAuth
import Security
import Testing
import os

/// An in-memory stand-in for the data-protection and legacy keychains.
final class FakeYouTubeKeychain: Sendable {
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

  var operations: YouTubeKeychainItem.Operations {
    YouTubeKeychainItem.Operations(
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

@Suite(.tags(.easy))
struct YouTubeKeychainItemUnitTestSuite {
  private static let accessibility = YouTubeKeychainItem.accessibility as String
  private let modern = FakeYouTubeKeychain.Key(
    dataProtection: true, service: "service", account: "account")
  private let legacy = FakeYouTubeKeychain.Key(
    dataProtection: false, service: "service", account: "account")

  @Test("Saving adds a data-protection item readable after first unlock")
  func savingAddsADataProtectionItemReadableAfterFirstUnlock() throws {
    let keychain = FakeYouTubeKeychain()
    let item = YouTubeKeychainItem(
      service: "service", account: "account", operations: keychain.operations)

    try item.save(Data("first".utf8))

    #expect(
      keychain.items == [modern: .init(data: Data("first".utf8), accessibility: Self.accessibility)]
    )
    #expect(try item.load() == Data("first".utf8))
  }

  @Test("Saving an existing item replaces its data and accessibility")
  func savingAnExistingItemReplacesItsDataAndAccessibility() throws {
    let keychain = FakeYouTubeKeychain()
    keychain.seed(modern, .init(data: Data("old".utf8), accessibility: nil))
    let item = YouTubeKeychainItem(
      service: "service", account: "account", operations: keychain.operations)

    try item.save(Data("new".utf8))

    #expect(
      keychain.items[modern] == .init(data: Data("new".utf8), accessibility: Self.accessibility))
  }

  @Test("A missing item deletes the legacy item and requires authorization again")
  func aMissingItemDeletesTheLegacyItemAndRequiresAuthorizationAgain() throws {
    let keychain = FakeYouTubeKeychain()
    keychain.seed(legacy, .init(data: Data("legacy".utf8), accessibility: nil))
    let item = YouTubeKeychainItem(
      service: "service", account: "account", operations: keychain.operations)

    #expect(try item.load() == nil)
    #expect(keychain.items.isEmpty)
  }

  @Test("Deleting removes both the data-protection and legacy items")
  func deletingRemovesBothTheDataProtectionAndLegacyItems() throws {
    let keychain = FakeYouTubeKeychain()
    keychain.seed(modern, .init(data: Data("modern".utf8), accessibility: Self.accessibility))
    keychain.seed(legacy, .init(data: Data("legacy".utf8), accessibility: nil))
    let item = YouTubeKeychainItem(
      service: "service", account: "account", operations: keychain.operations)

    try item.delete()
    try item.delete()

    #expect(keychain.items.isEmpty)
  }

  @Test("Keychain failures are reported with their status")
  func keychainFailuresAreReportedWithTheirStatus() {
    let keychain = FakeYouTubeKeychain()
    keychain.seed(modern, .init(data: Data("modern".utf8), accessibility: Self.accessibility))
    let item = YouTubeKeychainItem(
      service: "service", account: "account", operations: keychain.operations)

    keychain.fail("copyMatching", with: errSecInteractionNotAllowed)
    #expect(throws: YouTubeKeychainItem.StatusError(status: errSecInteractionNotAllowed)) {
      try item.load()
    }
    keychain.fail("update", with: errSecMissingEntitlement)
    #expect(throws: YouTubeKeychainItem.StatusError(status: errSecMissingEntitlement)) {
      try item.save(Data("new".utf8))
    }
    keychain.fail("delete", with: errSecInteractionNotAllowed)
    #expect(throws: YouTubeKeychainItem.StatusError(status: errSecInteractionNotAllowed)) {
      try item.delete()
    }
    #expect(keychain.items[modern]?.data == Data("modern".utf8))
  }

  @Test("A failed legacy cleanup does not fail loading")
  func aFailedLegacyCleanupDoesNotFailLoading() throws {
    let keychain = FakeYouTubeKeychain()
    keychain.fail("delete", with: errSecInteractionNotAllowed)
    let item = YouTubeKeychainItem(
      service: "service", account: "account", operations: keychain.operations)

    #expect(try item.load() == nil)
  }
}

@Suite(.tags(.easy))
struct YouTubeAuthKeychainStoresUnitTestSuite {
  @Test("The OAuth client store keeps its configuration in the data-protection keychain")
  func theOAuthClientStoreKeepsItsConfigurationInTheDataProtectionKeychain() throws {
    let keychain = FakeYouTubeKeychain()
    let store = OAuthClientConfigurationStore(
      service: "oauth", account: "client", keychainOperations: keychain.operations)
    let json = Data(
      """
      {"installed":{"client_id":"client.apps.googleusercontent.com","client_secret":"secret",
      "auth_uri":"https://accounts.google.com/o/oauth2/auth",
      "token_uri":"https://oauth2.googleapis.com/token","redirect_uris":["http://localhost"]}}
      """.utf8)

    #expect(try store.load() == nil)
    try store.save(json)
    #expect(try store.load()?.clientID == "client.apps.googleusercontent.com")
    #expect(
      keychain.items.keys.map(\.dataProtection) == [true])

    try store.delete()
    #expect(try store.load() == nil)
  }

  @Test("The OAuth client store maps Keychain failures")
  func theOAuthClientStoreMapsKeychainFailures() {
    let keychain = FakeYouTubeKeychain()
    keychain.fail("copyMatching", with: errSecMissingEntitlement)
    let store = OAuthClientConfigurationStore(
      service: "oauth", account: "client", keychainOperations: keychain.operations)

    #expect(throws: OAuthClientConfigurationStoreError.keychainFailure(errSecMissingEntitlement)) {
      try store.load()
    }
  }

  @Test("The authorization store keeps one data-protection item per client")
  func theAuthorizationStoreKeepsOneDataProtectionItemPerClient() throws {
    let keychain = FakeYouTubeKeychain()
    let store = YouTubeAuthorizationStore(
      service: "youtube", keychainOperations: keychain.operations)
    let state = YouTubeAuthorizationState(
      accessToken: "access", refreshToken: "refresh",
      expirationDate: Date(timeIntervalSince1970: 1_700_000_000))

    try store.save(state, clientID: "first")
    #expect(try store.load(clientID: "first") == state)
    #expect(try store.load(clientID: "second") == nil)

    try store.delete(clientID: "first")
    #expect(try store.load(clientID: "first") == nil)
    #expect(keychain.items.isEmpty)
  }

  @Test("The authorization store maps Keychain failures")
  func theAuthorizationStoreMapsKeychainFailures() {
    let keychain = FakeYouTubeKeychain()
    keychain.fail("add", with: errSecMissingEntitlement)
    let store = YouTubeAuthorizationStore(
      service: "youtube", keychainOperations: keychain.operations)
    let state = YouTubeAuthorizationState(
      accessToken: "access", refreshToken: nil, expirationDate: .distantFuture)

    #expect(throws: YouTubeAuthorizationStoreError.keychainFailure(errSecMissingEntitlement)) {
      try store.save(state, clientID: "client")
    }
  }
}
