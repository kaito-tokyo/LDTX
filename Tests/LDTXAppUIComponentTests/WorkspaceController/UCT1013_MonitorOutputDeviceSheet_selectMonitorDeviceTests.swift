// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletInterface
@testable import LDTXWorkspaceAppletUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1013: Select monitor device", .serialized)
  @MainActor
  struct UCT1013MonitorOutputDeviceSheetIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }
    @Test("UCT-1013.1: Selection starts empty and unavailable drafts clear before applying")
    func monitorDeviceSheetStartsUnselectedAndClearsUnavailableDraft() throws {
      let name = "MonitorSheet-\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: name))
      defer { defaults.removePersistentDomain(forName: name) }
      defaults.set("saved", forKey: WorkspaceAudioEngine.outputDevicePreferenceKey)
      var devices: [(uid: String, name: String)] = [
        ("saved", "Saved Device"), ("new", "New Device"),
      ]
      let sheet = MonitorOutputDeviceSheet(defaults: defaults, deviceProvider: { devices })
      defer { sheet.stop() }
      #expect(sheet.selectedUID == nil)
      #expect(sheet.table.selectedRow == -1)
      #expect(sheet.currentLabel.stringValue == "Saved Device")
      #expect(!sheet.applyButton.isEnabled)
      sheet.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      let selected = try #require(sheet.selectedUID)
      sheet.refreshDevices()
      #expect(sheet.selectedUID == selected)
      devices.removeAll { $0.uid == selected }
      sheet.refreshDevices()
      #expect(sheet.selectedUID == nil)
      #expect(!sheet.applyButton.isEnabled)
      #expect(defaults.string(forKey: WorkspaceAudioEngine.outputDevicePreferenceKey) == "saved")
      var closed = false
      sheet.onClose = { closed = true }
      sheet.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      sheet.applyButton.performClick(nil)
      #expect(closed)
      #expect(
        defaults.string(forKey: WorkspaceAudioEngine.outputDevicePreferenceKey) == devices[0].uid)
    }
  }
}
