// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

public struct SettingsRootView: View {
  @StateObject private var account = SettingsAccountModel(
    authorizationService: SettingsAuthorizationServiceFactory.make())
  @State private var monitorSettings = MonitorDeviceSettingsModel()
  @State private var error: Error?
  @State private var isShowingError = false

  public init() {}

  public var body: some View {
    SettingsContent(account: account, monitorSettings: monitorSettings)
      .onAppear {
        monitorSettings.reportError = {
          error = $0
          isShowingError = true
        }
      }
      .onDisappear {
        monitorSettings.reportError = { _ in }
        account.cancelAuthorization()
      }
      .alert("Error", isPresented: $isShowingError, presenting: error) { _ in
        Button("OK") { error = nil }
      } message: { error in
        Text(error.localizedDescription)
      }
  }
}
