// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@testable import LDTXYouTubeAuth
import Security
import XCTest

/// Exercises the real data-protection keychain from inside the signed `LDTX.app` host, whose
/// `keychain-access-groups` entitlement the hostless tests lack. Builds signed without
/// entitlements, such as ad-hoc CI builds, skip these tests.
final class YouTubeKeychainItemHostedTests: XCTestCase {
  private var item: YouTubeKeychainItem!

  override func setUpWithError() throws {
    item = YouTubeKeychainItem(
      service: "tokyo.kaito.ldtx.tests.keychain.\(UUID().uuidString)", account: "account",
      operations: .system)
    do {
      try item.delete()
    } catch let error as YouTubeKeychainItem.StatusError {
      // errSecMissingEntitlement is expected when the host is signed without entitlements.
      item = nil
      throw XCTSkip(
        "The data-protection keychain is unavailable to the test host (\(error.status)).")
    }
  }

  override func tearDownWithError() throws {
    try item?.delete()
  }

  func testSaveLoadUpdateAndDeleteInTheAppAccessGroup() throws {
    XCTAssertNil(try item.load())

    try item.save(Data("first".utf8))
    XCTAssertEqual(try item.load(), Data("first".utf8))
    try item.save(Data("second".utf8))
    XCTAssertEqual(try item.load(), Data("second".utf8))

    let attributes = try storedAttributes()
    XCTAssertEqual(
      attributes[kSecAttrAccessible as String] as? String,
      YouTubeKeychainItem.accessibility as String)
    let accessGroup = try XCTUnwrap(attributes[kSecAttrAccessGroup as String] as? String)
    XCTAssertTrue(
      accessGroup.hasSuffix(".tokyo.kaito.ldtx.LDTX"),
      "Unexpected access group \(accessGroup)")

    try item.delete()
    XCTAssertNil(try item.load())
  }

  func testLoadingWithoutAnItemDeletesTheLegacyItem() throws {
    let legacyQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: item.service,
      kSecAttrAccount as String: item.account,
      kSecUseDataProtectionKeychain as String: false,
    ]
    var legacyItem = legacyQuery
    legacyItem[kSecValueData as String] = Data("legacy".utf8)
    let addStatus = SecItemAdd(legacyItem as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw XCTSkip("The legacy keychain is unavailable to the test host (\(addStatus)).")
    }
    defer { SecItemDelete(legacyQuery as CFDictionary) }

    XCTAssertNil(try item.load())
    XCTAssertEqual(SecItemCopyMatching(legacyQuery as CFDictionary, nil), errSecItemNotFound)
  }

  private func storedAttributes() throws -> [String: Any] {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: item.service,
      kSecAttrAccount as String: item.account,
      kSecUseDataProtectionKeychain as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnAttributes as String: true,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    XCTAssertEqual(status, errSecSuccess)
    return try XCTUnwrap(result as? [String: Any])
  }
}
