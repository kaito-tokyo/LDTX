// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppUI
import LDTXWorkspace
import AppKit
import SwiftUI

struct SettingsView<AccountContent: View>: View {
  private let accountContent: AccountContent
  @AppStorage("tokyo.kaito.ldtx.application-output-preferences.v1")
  private var applicationOutputPreferencesData = Data()

  private var outputPreferences: ApplicationOutputPreferences {
    guard !applicationOutputPreferencesData.isEmpty,
      let preferences = try? ApplicationOutputPreferencesPersistenceCodec.decode(
        from: applicationOutputPreferencesData
      )
    else { return ApplicationOutputPreferences() }
    return preferences
  }

  init(@ViewBuilder accountContent: () -> AccountContent) {
    self.accountContent = accountContent()
  }

  var body: some View {
    TabView {
      Tab("Account", systemImage: "person.crop.circle") {
        accountContent
      }
      Tab("Output", systemImage: "folder") {
        Form {
          Section("Default Output Folder") {
            LabeledContent("Folder", value: outputPreferences.defaultOutputFolderPath ?? "~/Movies")
            HStack {
              Button("Choose Folder…", action: chooseDefaultOutputFolder)
              if outputPreferences.defaultOutputFolderPath != nil {
                Button("Use ~/Movies", action: resetDefaultOutputFolder)
              }
            }
          }
        }
        .formStyle(.grouped)
      }
      if let modelSettingsTab = AppFeatureComposition.modelSettingsTab() {
        Tab("Models", systemImage: "shippingbox") {
          modelSettingsTab
        }
      }
    }
    .frame(width: 560, height: 360)
  }

  private func chooseDefaultOutputFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Use Folder"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    saveOutputPreferences(
      ApplicationOutputPreferences(defaultOutputFolderPath: url.standardizedFileURL.path)
    )
  }

  private func resetDefaultOutputFolder() {
    saveOutputPreferences(ApplicationOutputPreferences())
  }

  private func saveOutputPreferences(_ preferences: ApplicationOutputPreferences) {
    guard let data = try? ApplicationOutputPreferencesPersistenceCodec.encode(preferences) else { return }
    applicationOutputPreferencesData = data
  }
}
