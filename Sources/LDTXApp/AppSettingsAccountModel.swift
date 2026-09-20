// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXAppInterface
import LDTXWorkspaceApplet
import Combine

@MainActor
final class AppSettingsAccountModel: @MainActor SettingsAccountProviding {
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
}
