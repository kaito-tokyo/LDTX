// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCorelibs
import Security
import Testing

@Suite(.tags(.easy))
struct DataProtectionKeychainItemUnitTestSuite {
  private static let accessibility = DataProtectionKeychainItem.accessibility as String
  private let modern = FakeDataProtectionKeychain.Key(
    dataProtection: true, service: "service", account: "account")
  private let legacy = FakeDataProtectionKeychain.Key(
    dataProtection: false, service: "service", account: "account")

  @Test("Saving adds a data-protection item readable after first unlock")
  func savingAddsADataProtectionItemReadableAfterFirstUnlock() throws {
    let keychain = FakeDataProtectionKeychain()
    let item = DataProtectionKeychainItem(
      service: "service", account: "account", operations: keychain.operations)

    try item.save(Data("first".utf8))

    #expect(
      keychain.items == [modern: .init(data: Data("first".utf8), accessibility: Self.accessibility)]
    )
    #expect(try item.load() == Data("first".utf8))
  }

  @Test("Saving an existing item replaces its data and accessibility")
  func savingAnExistingItemReplacesItsDataAndAccessibility() throws {
    let keychain = FakeDataProtectionKeychain()
    keychain.seed(modern, .init(data: Data("old".utf8), accessibility: nil))
    let item = DataProtectionKeychainItem(
      service: "service", account: "account", operations: keychain.operations)

    try item.save(Data("new".utf8))

    #expect(
      keychain.items[modern] == .init(data: Data("new".utf8), accessibility: Self.accessibility))
  }

  @Test("A missing item deletes the legacy item and requires the credential again")
  func aMissingItemDeletesTheLegacyItemAndRequiresTheCredentialAgain() throws {
    let keychain = FakeDataProtectionKeychain()
    keychain.seed(legacy, .init(data: Data("legacy".utf8), accessibility: nil))
    let item = DataProtectionKeychainItem(
      service: "service", account: "account", operations: keychain.operations)

    #expect(try item.load() == nil)
    #expect(keychain.items.isEmpty)
  }

  @Test("Deleting removes both the data-protection and legacy items")
  func deletingRemovesBothTheDataProtectionAndLegacyItems() throws {
    let keychain = FakeDataProtectionKeychain()
    keychain.seed(modern, .init(data: Data("modern".utf8), accessibility: Self.accessibility))
    keychain.seed(legacy, .init(data: Data("legacy".utf8), accessibility: nil))
    let item = DataProtectionKeychainItem(
      service: "service", account: "account", operations: keychain.operations)

    try item.delete()
    try item.delete()

    #expect(keychain.items.isEmpty)
  }

  @Test("Keychain failures are reported with their status")
  func keychainFailuresAreReportedWithTheirStatus() {
    let keychain = FakeDataProtectionKeychain()
    keychain.seed(modern, .init(data: Data("modern".utf8), accessibility: Self.accessibility))
    let item = DataProtectionKeychainItem(
      service: "service", account: "account", operations: keychain.operations)

    keychain.fail("copyMatching", with: errSecInteractionNotAllowed)
    #expect(throws: DataProtectionKeychainItem.StatusError(status: errSecInteractionNotAllowed)) {
      try item.load()
    }
    keychain.fail("update", with: errSecMissingEntitlement)
    #expect(throws: DataProtectionKeychainItem.StatusError(status: errSecMissingEntitlement)) {
      try item.save(Data("new".utf8))
    }
    keychain.fail("delete", with: errSecInteractionNotAllowed)
    #expect(throws: DataProtectionKeychainItem.StatusError(status: errSecInteractionNotAllowed)) {
      try item.delete()
    }
    #expect(keychain.items[modern]?.data == Data("modern".utf8))
  }

  @Test("A failed legacy cleanup does not fail loading")
  func aFailedLegacyCleanupDoesNotFailLoading() throws {
    let keychain = FakeDataProtectionKeychain()
    keychain.fail("delete", with: errSecInteractionNotAllowed)
    let item = DataProtectionKeychainItem(
      service: "service", account: "account", operations: keychain.operations)

    #expect(try item.load() == nil)
  }
}
