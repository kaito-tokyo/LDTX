// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspace
import SwiftUI

public struct SettingsView<AccountContent: View>: View {
  private let accountContent: AccountContent
  private let settingsStore: ApplicationSettingsStore
  @State private var outputPreferences = ApplicationOutputPreferences()

  public init(
    userDefaults: UserDefaults = .standard,
    @ViewBuilder accountContent: () -> AccountContent
  ) {
    self.accountContent = accountContent()
    self.settingsStore = ApplicationSettingsStore(userDefaults: userDefaults)
  }

  public var body: some View {
    TabView {
      Tab("Account", systemImage: "person.crop.circle") { accountContent }
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
    }
    .frame(width: 560, height: 360)
    .task { outputPreferences = settingsStore.loadApplicationOutputPreferences() }
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
      ApplicationOutputPreferences(defaultOutputFolderPath: url.standardizedFileURL.path))
  }

  private func resetDefaultOutputFolder() {
    saveOutputPreferences(ApplicationOutputPreferences())
  }

  private func saveOutputPreferences(_ preferences: ApplicationOutputPreferences) {
    outputPreferences = preferences
    settingsStore.saveApplicationOutputPreferences(preferences)
  }
}
