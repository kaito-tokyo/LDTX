// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXCorelibs
@testable import LDTXWorkspaceAppletUI
import Security
import XCTest

/// Saves and loads the YouTube RTMPS stream-key collection through the real data-protection
/// keychain from inside the signed `LDTX.app` host. A unique service keeps the user's own stream
/// keys untouched. Builds signed without entitlements, such as ad-hoc CI builds, skip these tests.
@MainActor
final class YouTubeStreamKeyKeychainHostedTests: XCTestCase {
  private var item: DataProtectionKeychainItem!
  private var suiteName: String!

  override func setUp() async throws {
    item = DataProtectionKeychainItem(
      service: "tokyo.kaito.ldtx.tests.stream-keys.\(UUID().uuidString)",
      account: WorkspaceAppletData.streamKeyKeychainAccount)
    suiteName = "YouTubeStreamKeyKeychainHostedTests.\(UUID().uuidString)"
    do {
      try item.delete()
    } catch let error as DataProtectionKeychainItem.StatusError {
      // errSecMissingEntitlement is expected when the host is signed without entitlements.
      item = nil
      throw XCTSkip(
        "The data-protection keychain is unavailable to the test host (\(error.status)).")
    }
  }

  override func tearDown() async throws {
    try item?.delete()
    if let suiteName { UserDefaults().removePersistentDomain(forName: suiteName) }
  }

  func testStreamKeyCollectionRoundTripsThroughTheAppAccessGroup() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let appletData = WorkspaceAppletData(userDefaults: defaults, streamKeyKeychainItem: item)
    XCTAssertEqual(try appletData.loadYouTubeStreamKeyConfigurations(), [])

    let configurations = [
      YouTubeRTMPSStreamKeyConfiguration(
        id: "landscape", name: "Landscape", streamURL: "rtmps://a.rtmp.youtube.com/live2",
        streamKey: "hosted-test-key")
    ]
    try appletData.saveYouTubeStreamKeyConfigurations(configurations)
    try appletData.saveYouTubeStreamKeyConfigurations(configurations)

    let reloaded = WorkspaceAppletData(userDefaults: defaults, streamKeyKeychainItem: item)
    XCTAssertEqual(try reloaded.loadYouTubeStreamKeyConfigurations(), configurations)

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: item.service,
      kSecAttrAccount as String: item.account,
      kSecUseDataProtectionKeychain as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnAttributes as String: true,
    ]
    var result: CFTypeRef?
    XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
    let attributes = try XCTUnwrap(result as? [String: Any])
    XCTAssertEqual(
      attributes[kSecAttrAccessible as String] as? String,
      DataProtectionKeychainItem.accessibility as String)
    let accessGroup = try XCTUnwrap(attributes[kSecAttrAccessGroup as String] as? String)
    XCTAssertTrue(
      accessGroup.hasSuffix(".tokyo.kaito.ldtx.LDTX"), "Unexpected access group \(accessGroup)")
  }
}
