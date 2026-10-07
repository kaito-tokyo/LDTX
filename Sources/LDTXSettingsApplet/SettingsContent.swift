// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct SettingsContent<Account: SettingsAccountProviding>: View {
  @ObservedObject private var account: Account
  private let monitorSettings: MonitorDeviceSettingsModel

  init(account: Account, monitorSettings: MonitorDeviceSettingsModel) {
    self.account = account
    self.monitorSettings = monitorSettings
  }

  public var body: some View {
    SettingsView(monitorSettings: monitorSettings) {
      YouTubeAccountSettingsView(
        oauthStatus: account.oauthStatus,
        authorizationStatus: account.authorizationStatus,
        isImportingOAuthClient: $account.isImportingOAuthClient,
        canAuthorize: account.canAuthorize,
        restoreAuthorization: account.restoreAuthorization,
        authorizeYouTube: account.authorizeYouTube,
        loadOAuthClient: account.loadOAuthClient(from:)
      )
    }
  }
}
