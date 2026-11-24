// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletStore
import SwiftUI

public struct SettingsView<AccountContent: View, StreamKeysContent: View>: View {
  private let accountContent: AccountContent
  private let streamKeysContent: StreamKeysContent
  private let settingsStore: ApplicationSettingsStore
  private let monitorSettings: MonitorDeviceSettingsModel
  @State private var outputPreferences = ApplicationOutputPreferences()
  @AppStorage(ApplicationSettingsTab.defaultsKey) private var selectedTab =
    ApplicationSettingsTab.account

  public init(
    userDefaults: UserDefaults = .standard,
    @ViewBuilder accountContent: () -> AccountContent,
    @ViewBuilder streamKeysContent: () -> StreamKeysContent
  ) {
    self.accountContent = accountContent()
    self.streamKeysContent = streamKeysContent()
    self.settingsStore = ApplicationSettingsStore(userDefaults: userDefaults)
    self.monitorSettings = MonitorDeviceSettingsModel(defaults: userDefaults)
  }

  init(
    monitorSettings: MonitorDeviceSettingsModel,
    @ViewBuilder accountContent: () -> AccountContent,
    @ViewBuilder streamKeysContent: () -> StreamKeysContent
  ) {
    self.accountContent = accountContent()
    self.streamKeysContent = streamKeysContent()
    self.settingsStore = ApplicationSettingsStore(userDefaults: .standard)
    self.monitorSettings = monitorSettings
  }

  public var body: some View {
    TabView(selection: $selectedTab) {
      Tab("Account", systemImage: "person.crop.circle", value: .account) { accountContent }
      Tab("Audio", systemImage: "speaker.wave.2", value: .audio) {
        MonitorDeviceSettingsView(model: monitorSettings)
      }
      Tab("Output", systemImage: "folder", value: .output) {
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
            LabeledContent("Folder", value: outputPreferences.screenshotsFolderPath ?? "~/Movies")
            HStack {
              Button("Choose Folder…", action: chooseScreenshotsFolder)
              if outputPreferences.screenshotsFolderPath != nil {
                Button("Use ~/Movies") {
                  var preferences = outputPreferences
                  preferences.setScreenshotsFolder(nil)
                  saveOutputPreferences(preferences)
                }
              }
            }
          }
        }
        .formStyle(.grouped)
      }
      Tab("Stream Keys", systemImage: "key", value: .streamKeys) { streamKeysContent }
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
    preferences.setDefaultOutputFolder(url)
    saveOutputPreferences(preferences)
  }

  private func resetDefaultOutputFolder() {
    var preferences = outputPreferences
    preferences.setDefaultOutputFolder(nil)
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
    preferences.setScreenshotsFolder(url)
    saveOutputPreferences(preferences)
  }

  private func saveOutputPreferences(_ preferences: ApplicationOutputPreferences) {
    outputPreferences = preferences
    settingsStore.saveApplicationOutputPreferences(preferences)
  }
}
