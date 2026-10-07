// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppAuth
import Foundation
@testable import LDTXYouTubeAuth
import Testing

@Suite
struct YouTubeAuthFileIntegrationTestSuite {
  private let clientJSON = Data(
    #"{"installed":{"client_id":"local-test","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token"}}"#
      .utf8)

  @Test @MainActor func selectsOnlyAnExistingFileUnderTheApplicationBundleID() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let bundleID = "tokyo.kaito.ldtx.tests"
    let applicationDirectory = directory.appendingPathComponent(bundleID)
    try FileManager.default.createDirectory(
      at: applicationDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(
      YouTubeAuthorizationService.existingApplicationFile(
        applicationSupportDirectory: directory, bundleIdentifier: bundleID) == nil)
    let url = applicationDirectory.appendingPathComponent(".YouTubeAuth")
    try Data().write(to: url)
    #expect(
      YouTubeAuthorizationService.existingApplicationFile(
        applicationSupportDirectory: directory, bundleIdentifier: bundleID) == url)
    #expect(
      YouTubeAuthorizationService.existingApplicationFile(
        applicationSupportDirectory: directory, bundleIdentifier: "other.bundle") == nil)
  }

  @Test func storesShareFileAndRestoreAfterRecreation() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent(".YouTubeAuth")
    try Data().write(to: url)
    let file = YouTubeAuthFile(url: url)
    let oauth = OAuthClientConfigurationStore(file: file)
    let authorization = YouTubeAuthorizationStore(file: file)
    #expect(try oauth.load() == nil)
    try oauth.save(clientJSON)
    let state = OIDAuthState(
      authorizationResponse: nil, tokenResponse: nil, registrationResponse: nil)
    try authorization.save(state, clientID: "local-test")
    let reopenedFile = YouTubeAuthFile(url: url)
    #expect(try OAuthClientConfigurationStore(file: reopenedFile).load()?.clientID == "local-test")
    #expect(try YouTubeAuthorizationStore(file: reopenedFile).load(clientID: "local-test") != nil)
    try authorization.delete(clientID: "local-test")
    #expect(try oauth.load()?.clientID == "local-test")
    #expect(try authorization.load(clientID: "local-test") == nil)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try oauth.delete()
    #expect(try oauth.load() == nil)
  }

  @Test func corruptFileDoesNotFallBackOrGetOverwritten() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let corrupt = Data("invalid JSON".utf8)
    try corrupt.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let store = OAuthClientConfigurationStore(file: YouTubeAuthFile(url: url))
    #expect(throws: (any Error).self) { try store.load() }
    #expect(throws: (any Error).self) { try store.save(clientJSON) }
    #expect(try Data(contentsOf: url) == corrupt)
  }
}
