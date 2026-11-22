// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCorelibs
@testable import LDTXYouTubeAuth
import Security
import Testing

@Suite(.tags(.easy))
struct YouTubeAuthKeychainStoresUnitTestSuite {
  @Test("The OAuth client store keeps its configuration in the data-protection keychain")
  func theOAuthClientStoreKeepsItsConfigurationInTheDataProtectionKeychain() throws {
    let keychain = FakeDataProtectionKeychain()
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
    let keychain = FakeDataProtectionKeychain()
    keychain.fail("copyMatching", with: errSecMissingEntitlement)
    let store = OAuthClientConfigurationStore(
      service: "oauth", account: "client", keychainOperations: keychain.operations)

    #expect(throws: OAuthClientConfigurationStoreError.keychainFailure(errSecMissingEntitlement)) {
      try store.load()
    }
  }

  @Test("The authorization store keeps one data-protection item per client")
  func theAuthorizationStoreKeepsOneDataProtectionItemPerClient() throws {
    let keychain = FakeDataProtectionKeychain()
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
    let keychain = FakeDataProtectionKeychain()
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
