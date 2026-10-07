// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
@testable import LDTXProgramRuntime
@testable import LDTXSettingsApplet
@testable import LDTXWorkspaceAppletController
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1013: Select monitor device", .serialized)
  @MainActor
  struct UCT1013MonitorDeviceSettingsIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    @Test("UCT-1013.1: Disappearing candidates do not change assignment")
    func preservesAssignmentAndClearsUnavailableDraft() throws {
      let suite = "MonitorSettings-\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      defaults.set("saved", forKey: WorkspaceAudioEngine.outputDevicePreferenceKey)
      var devices = [MonitorOutputDevice(id: "saved", name: "Saved Device")]
      let model = MonitorDeviceSettingsModel(
        defaults: defaults, observesChanges: false, deviceProvider: { devices })
      model.refresh()
      #expect(model.currentName == "Saved Device")
      devices = []
      model.select("saved")
      #expect(model.currentName == "Unavailable: saved")
      #expect(defaults.string(forKey: WorkspaceAudioEngine.outputDevicePreferenceKey) == "saved")
    }

    @Test("UCT-1013.2: Selection immediately persists globally")
    func appliesGlobalAssignmentWithoutEditingWorkspace() async throws {
      let suite = "MonitorSettings-\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let devices = [MonitorOutputDevice(id: "new", name: "New Device")]
      let model = MonitorDeviceSettingsModel(
        defaults: defaults, observesChanges: false, deviceProvider: { devices })
      let firstDefaults = try #require(MonitorReadingDefaults(suiteName: suite))
      let secondDefaults = try #require(MonitorReadingDefaults(suiteName: suite))
      let firstEngine = WorkspaceAudioEngine(defaults: firstDefaults)
      let secondEngine = WorkspaceAudioEngine(defaults: secondDefaults)
      defer {
        withExtendedLifetime(firstEngine) {}
        withExtendedLifetime(secondEngine) {}
      }
      firstEngine.configureMonitor(routes: [], master: 1)
      secondEngine.configureMonitor(routes: [], master: 1)
      let document = WorkspaceDocument()
      defer { document.close() }
      document.updateChangeCount(.changeCleared)
      model.refresh()
      #expect(model.currentUID == "")
      model.select("new")
      #expect(model.currentUID == "new")
      NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
      for _ in 0..<100 {
        if firstDefaults.monitorUID == "new", secondDefaults.monitorUID == "new" { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(firstDefaults.monitorUID == "new" && secondDefaults.monitorUID == "new")
      let restored = MonitorDeviceSettingsModel(
        defaults: defaults, observesChanges: false, deviceProvider: { devices })
      restored.refresh()
      #expect(restored.currentName == "New Device")
      model.select("")
      restored.refresh()
      #expect(restored.currentName == "System Default")
      #expect(!document.isDocumentEdited)
    }

    @Test("UCT-1013.3: Discovery failures preserve assignment and report once until recovery")
    func reportsFailureAndRecovery() throws {
      let suite = "MonitorSettings-\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      defaults.set("saved", forKey: WorkspaceAudioEngine.outputDevicePreferenceKey)
      var fails = true
      let model = MonitorDeviceSettingsModel(
        defaults: defaults, observesChanges: false,
        deviceProvider: {
          if fails { throw CocoaError(.fileReadUnknown) }
          return [MonitorOutputDevice(id: "saved", name: "Saved Device")]
        })
      var errors = 0
      model.reportError = { _ in errors += 1 }
      model.refresh()
      model.refresh()
      model.select("saved")
      #expect(errors == 1 && model.discoveryFailed)
      #expect(model.currentUID == "saved")
      fails = false
      model.refresh()
      #expect(!model.discoveryFailed && model.currentName == "Saved Device")
      fails = true
      model.refresh()
      #expect(errors == 2 && model.currentUID == "saved")
    }
  }
}

private final class MonitorReadingDefaults: UserDefaults, @unchecked Sendable {
  private let monitorLock = NSLock()
  private var lastMonitorUID: String?
  var monitorUID: String? { monitorLock.withLock { lastMonitorUID } }

  override func string(forKey defaultName: String) -> String? {
    let value = super.string(forKey: defaultName)
    if defaultName == WorkspaceAudioEngine.outputDevicePreferenceKey {
      monitorLock.withLock { lastMonitorUID = value }
    }
    return value
  }
}
