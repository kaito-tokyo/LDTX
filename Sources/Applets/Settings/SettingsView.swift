// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletStore
import SwiftUI

public struct SettingsView<AccountContent: View>: View {
  private let accountContent: AccountContent
  private let settingsStore: ApplicationSettingsStore
  private let monitorSettings: MonitorDeviceSettingsModel
  @State private var outputPreferences = ApplicationOutputPreferences()

  public init(
    userDefaults: UserDefaults = .standard,
    @ViewBuilder accountContent: () -> AccountContent
  ) {
    self.accountContent = accountContent()
    self.settingsStore = ApplicationSettingsStore(userDefaults: userDefaults)
    self.monitorSettings = MonitorDeviceSettingsModel(defaults: userDefaults)
  }

  init(
    monitorSettings: MonitorDeviceSettingsModel,
    @ViewBuilder accountContent: () -> AccountContent
  ) {
    self.accountContent = accountContent()
    self.settingsStore = ApplicationSettingsStore(userDefaults: .standard)
    self.monitorSettings = monitorSettings
  }

  public var body: some View {
    TabView {
      Tab("Account", systemImage: "person.crop.circle") { accountContent }
      Tab("Audio", systemImage: "speaker.wave.2") {
        MonitorDeviceSettingsView(model: monitorSettings)
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
          Section("Screenshots Folder") {
            LabeledContent("Folder", value: outputPreferences.screenshotsFolderPath ?? "~/Pictures")
            HStack {
              Button("Choose Folder…", action: chooseScreenshotsFolder)
              if outputPreferences.screenshotsFolderPath != nil {
                Button("Use ~/Pictures") {
                  var preferences = outputPreferences
                  preferences.screenshotsFolderPath = nil
                  saveOutputPreferences(preferences)
                }
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
    var preferences = outputPreferences
    preferences.defaultOutputFolderPath = url.standardizedFileURL.path
    saveOutputPreferences(preferences)
  }

  private func resetDefaultOutputFolder() {
    var preferences = outputPreferences
    preferences.defaultOutputFolderPath = nil
    saveOutputPreferences(preferences)
  }

  private func chooseScreenshotsFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Use Folder"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    var preferences = outputPreferences
    preferences.screenshotsFolderPath = url.standardizedFileURL.path
    saveOutputPreferences(preferences)
  }

  private func saveOutputPreferences(_ preferences: ApplicationOutputPreferences) {
    outputPreferences = preferences
    settingsStore.saveApplicationOutputPreferences(preferences)
  }
}
