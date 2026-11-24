// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

public struct SettingsRootView<StreamKeysContent: View>: View {
  @StateObject private var account = SettingsAccountModel(
    authorizationService: SettingsAuthorizationServiceFactory.make())
  @State private var monitorSettings = MonitorDeviceSettingsModel()
  @State private var error: Error?
  @State private var isShowingError = false
  private let streamKeysContent: StreamKeysContent

  /// - Parameter streamKeysContent: The Stream Keys tab, supplied by the composition root
  ///   because the stream key store belongs to the Workspace Applet.
  public init(@ViewBuilder streamKeysContent: () -> StreamKeysContent) {
    self.streamKeysContent = streamKeysContent()
  }

  public var body: some View {
    SettingsContent(account: account, monitorSettings: monitorSettings) {
      streamKeysContent
    }
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
