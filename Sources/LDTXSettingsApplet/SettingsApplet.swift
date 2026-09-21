// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Combine
import LDTXAppInterface
import LDTXWorkspaceApplet
import LDTXYouTubeAuth
import SwiftUI

@MainActor
final class SettingsAccountModel: @MainActor SettingsAccountProviding {
  let objectWillChange = ObservableObjectPublisher()

  private let oauth: OAuthClientState
  private let auth: YouTubeAuthState
  private var cancellables = Set<AnyCancellable>()

  init(oauth: OAuthClientState, auth: YouTubeAuthState) {
    self.oauth = oauth
    self.auth = auth
    oauth.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    auth.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }

  var oauthStatus: String { oauth.status }
  var authorizationStatus: String { auth.status }
  var isImportingOAuthClient: Bool {
    get { oauth.isImportingOAuthClient }
    set { oauth.isImportingOAuthClient = newValue }
  }
  var canAuthorize: Bool { oauth.configuration != nil && !auth.isAuthorizing }

  func restoreAuthorization() { auth.restore(for: oauth.configuration) }
  func authorizeYouTube() { auth.authorize(configuration: oauth.configuration) }
  func loadOAuthClient(from url: URL) -> Bool { oauth.load(from: url) != nil }
  func cancelAuthorization() { auth.cancelAuthorization() }
}

public final class SettingsApplet: NSWindowController {
  @discardableResult
  public static func open() -> SettingsApplet {
    let applet = SettingsApplet()
    applet.showWindow(nil)
    applet.window?.makeKeyAndOrderFront(nil)
    return applet
  }

  private let account: SettingsAccountModel

  public init() {
    let service = YouTubeClientService(
      authorizationService: YouTubeAuthorizationService(
        authorizationStore: YouTubeAuthorizationStore(service: "tokyo.kaito.ldtx.youtube-auth"),
        oauthClientStore: OAuthClientConfigurationStore(service: "tokyo.kaito.ldtx.oauth-client")
      )
    )
    let oauth = OAuthClientState(
      youtubeClientService: service,
      restoresPersistedOAuthClient: !LDTXRuntimeMode.isUITesting && !LDTXRuntimeMode.isUnitTesting)
    let auth = YouTubeAuthState(youtubeClientService: service)
    account = SettingsAccountModel(oauth: oauth, auth: auth)
    let content = SettingsContent(account: account)
    let window = NSWindow(contentViewController: NSHostingController(rootView: content))
    window.title = "Settings"
    window.setContentSize(NSSize(width: 600, height: 480))
    window.center()
    window.isReleasedWhenClosed = false
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  public override func windowWillClose(_ notification: Notification) {
    account.cancelAuthorization()
    super.windowWillClose(notification)
  }
}
