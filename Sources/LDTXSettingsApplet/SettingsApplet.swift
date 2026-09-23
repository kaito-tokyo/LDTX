// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Combine
import LDTXYouTubeAuth
import SwiftUI

@MainActor
protocol SettingsAccountProviding: ObservableObject {
  var oauthStatus: String { get }
  var authorizationStatus: String { get }
  var isImportingOAuthClient: Bool { get set }
  var canAuthorize: Bool { get }

  func restoreAuthorization()
  func authorizeYouTube()
  @discardableResult func loadOAuthClient(from url: URL) -> Bool
}

@MainActor
protocol SettingsAuthorizationProviding {
  func restorePersistedOAuthClient() throws -> GoogleOAuthClientConfiguration?
  func restoreStoredAuthorization(
    configuration: GoogleOAuthClientConfiguration
  ) async throws -> YouTubeAuthorizationService.AuthorizationRestoreResult
  func loadOAuthClient(data: Data) throws -> GoogleOAuthClientConfiguration
  func authorize(configuration: GoogleOAuthClientConfiguration) async throws
  func cancelAuthorization()
}

@MainActor
private struct KeychainSettingsAuthorizationProvider: SettingsAuthorizationProviding {
  let service: YouTubeAuthorizationService

  func restorePersistedOAuthClient() throws -> GoogleOAuthClientConfiguration? {
    try service.restorePersistedOAuthClient()?.configuration
  }

  func restoreStoredAuthorization(
    configuration: GoogleOAuthClientConfiguration
  ) async throws -> YouTubeAuthorizationService.AuthorizationRestoreResult {
    try await service.restoreStoredAuthorization(configuration: configuration)
  }

  func loadOAuthClient(data: Data) throws -> GoogleOAuthClientConfiguration {
    try service.loadOAuthClient(data: data).configuration
  }

  func authorize(configuration: GoogleOAuthClientConfiguration) async throws {
    _ = try await service.authorize(configuration: configuration)
  }

  func cancelAuthorization() { service.cancelAuthorization() }
}

@MainActor
final class SettingsAccountModel: @MainActor SettingsAccountProviding {
  let objectWillChange = ObservableObjectPublisher()

  private let authorizationService: any SettingsAuthorizationProviding
  private var configuration: GoogleOAuthClientConfiguration?
  private(set) var oauthStatus = "No OAuth client" { willSet { objectWillChange.send() } }
  private(set) var authorizationStatus = "Not authorized" {
    willSet { objectWillChange.send() }
  }
  var isImportingOAuthClient = false { willSet { objectWillChange.send() } }
  private(set) var isAuthorizing = false { willSet { objectWillChange.send() } }

  init(authorizationService: any SettingsAuthorizationProviding) {
    self.authorizationService = authorizationService
  }

  var canAuthorize: Bool { configuration != nil && !isAuthorizing }

  func restoreAuthorization() {
    Task {
      do {
        configuration = try authorizationService.restorePersistedOAuthClient()
        guard let configuration else {
          oauthStatus = "No OAuth client"
          authorizationStatus = "Not authorized"
          return
        }
        oauthStatus = "OAuth client loaded: \(Self.redacted(configuration.clientID))"
        switch try await authorizationService.restoreStoredAuthorization(
          configuration: configuration)
        {
        case .notAuthorized:
          authorizationStatus = "Not authorized"
        case .authorized:
          authorizationStatus = "Authorized"
        }
      } catch {
        oauthStatus = "OAuth client restore failed: \(error.localizedDescription)"
        authorizationStatus = "Authorization restore failed: \(error.localizedDescription)"
      }
    }
  }

  func authorizeYouTube() {
    guard let configuration, !isAuthorizing else { return }
    isAuthorizing = true
    Task {
      defer { isAuthorizing = false }
      do {
        try await authorizationService.authorize(configuration: configuration)
        authorizationStatus = "Authorized"
      } catch {
        authorizationStatus = "Authorization failed: \(error.localizedDescription)"
      }
    }
  }

  func loadOAuthClient(from url: URL) -> Bool {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      let loaded = try authorizationService.loadOAuthClient(data: Data(contentsOf: url))
      configuration = loaded
      oauthStatus = "OAuth client loaded: \(Self.redacted(loaded.clientID)) (Keychain)"
      authorizationStatus = "Not authorized"
      return true
    } catch {
      oauthStatus = "OAuth client failed: \(error.localizedDescription)"
      return false
    }
  }

  func cancelAuthorization() {
    authorizationService.cancelAuthorization()
    isAuthorizing = false
  }

  private static func redacted(_ clientID: String) -> String {
    guard clientID.count > 12 else { return "loaded" }
    return "\(clientID.prefix(8))...\(clientID.suffix(4))"
  }
}

public final class SettingsApplet: NSWindowController, NSWindowDelegate {
  public static func open(
    completionHandler: @escaping (NSWindow?, (any Error)?) -> Void
  ) {
    let applet = SettingsApplet()
    applet.showWindow(nil)
    applet.window?.makeKeyAndOrderFront(nil)
    completionHandler(applet.window, nil)
  }

  private let account: SettingsAccountModel

  public init() {
    let authorizationService = KeychainSettingsAuthorizationProvider(
      service: YouTubeAuthorizationService(
        authorizationStore: YouTubeAuthorizationStore(),
        oauthClientStore: OAuthClientConfigurationStore()
      ))
    account = SettingsAccountModel(authorizationService: authorizationService)
    let content = SettingsContent(account: account)
    let window = NSWindow(contentViewController: NSHostingController(rootView: content))
    window.title = "Settings"
    window.setContentSize(NSSize(width: 600, height: 480))
    window.center()
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  public func windowWillClose(_ notification: Notification) {
    account.cancelAuthorization()
  }
}
