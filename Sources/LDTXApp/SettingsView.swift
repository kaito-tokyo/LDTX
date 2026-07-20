// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppUI
import SwiftUI

struct SettingsView<AccountContent: View>: View {
  private let accountContent: AccountContent

  init(@ViewBuilder accountContent: () -> AccountContent) {
    self.accountContent = accountContent()
  }

  var body: some View {
    TabView {
      Tab("Account", systemImage: "person.crop.circle") {
        accountContent
      }
      if let modelSettingsTab = AppFeatureComposition.modelSettingsTab() {
        Tab("Models", systemImage: "shippingbox") {
          modelSettingsTab
        }
      }
    }
    .frame(width: 560, height: 360)
  }
}
