// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXBackgroundSegmentation
import LDTXDeviceRegistry
import LDTXProgramRuntime
import LDTXProtos
import LDTXTaskQueue
@testable import LDTXWorkspaceAppletController
@testable import LDTXWorkspaceAppletUI
import Observation
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1011: edit-master-volumes", .serialized)
  @MainActor
  struct UCT1011MasterVolumeEditorIntegrationTestSuite {
    private static var controller: NSDocumentController {
      UIComponentTestEnvironment.documentController
    }
    init() { _ = Self.controller }

    @Test("Injected AppletData selects the Program edited by the master volume field")
    func programSelectionUsesInjectedAppletData() throws {
      let suite = "InjectedProgramSelection.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let data = WorkspaceAppletData(userDefaults: defaults)
      let store = WorkspaceStateService(definition: .init(), preferences: .init())
      let url = URL(fileURLWithPath: "/tmp/InjectedProgramSelection.ldtxworkspace")
      store.localStateURL = url
      store.workspaceDefinition.programs = [
        .with { $0.internalID = 100 }, .with { $0.internalID = 200 },
      ]
      data.updateState(for: url) { $0.selectedProgramInternalID = 200 }
      let editor = MasterVolumeEditor(
        stateService: store, appletData: data, peakMeter: .init(),
        reportError: { _ in })
      _ = editor.view
      let field = editor.masterFields[0]
      field.stringValue = "-12"
      field.controlTextDidChange(.init(name: NSControl.textDidChangeNotification))
      field.controlTextDidChange(.init(name: NSControl.textDidChangeNotification))
      #expect(store.workspacePreferences.landscapeProgramPreferences[100] == nil)
      #expect(
        store.workspacePreferences.landscapeProgramPreferences[200]?.audioMasterVolumeDecibels
          .double == -12)
      data.updateState(for: url) { $0.selectedProgramInternalID = 100 }
      editor.refresh()
      field.stringValue = "-6"
      field.controlTextDidChange(.init(name: NSControl.textDidChangeNotification))
      field.controlTextDidChange(.init(name: NSControl.textDidChangeNotification))
      #expect(
        store.workspacePreferences.landscapeProgramPreferences[100]?.audioMasterVolumeDecibels
          .double == -6)
      #expect(
        store.workspacePreferences.landscapeProgramPreferences[200]?.audioMasterVolumeDecibels
          .double == -12)
    }

    @Test("Master volume writes on text change without Return")
    func volumeWritesImmediately() throws {
      let store = WorkspaceStateService(definition: .init(), preferences: .init())
      store.workspaceDefinition.programs = [.with { $0.internalID = 100 }]
      let editor = MasterVolumeEditor(
        stateService: store, appletData: WorkspaceAppletData(), peakMeter: .init(), reportError: { _ in })
      _ = editor.view
      let field = editor.masterFields[0]
      field.stringValue = "-12.5"
      field.controlTextDidChange(.init(name: NSControl.textDidChangeNotification))
      #expect(store.workspacePreferences.landscapeProgramPreferences[100]?.audioMasterVolumeDecibels.double == -12.5)
      let previous = store.workspacePreferences
      field.stringValue = "-"
      field.controlTextDidChange(.init(name: NSControl.textDidChangeNotification))
      #expect(store.workspacePreferences == previous)
      #expect(field.stringValue == "-")
      for text in ["100", "-81", "20.1"] {
        field.stringValue = text
        field.controlTextDidChange(.init(name: NSControl.textDidChangeNotification))
        #expect(store.workspacePreferences == previous)
        #expect(field.stringValue == text)
      }
      for text in ["-80", "20"] {
        field.stringValue = text
        field.controlTextDidChange(.init(name: NSControl.textDidChangeNotification))
        #expect(
          store.workspacePreferences.landscapeProgramPreferences[100]?.audioMasterVolumeDecibels
            .double == Double(text))
      }
    }

    @Test("UCT-1011.1: Master volume edits and model updates are reflected independently")
    func masterEditorObservesAndEditsVolumesIndependently() async throws {
      let serviceAppletData = WorkspaceAppletData()
      _ = NSApplication.shared
      let service = WorkspaceStateService(definition: .init(), preferences: .init())
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 100
      service.workspaceDefinition.programs = [program]
      let editor = MasterVolumeEditor(
        stateService: service, appletData: serviceAppletData, peakMeter: .init(),
        reportError: { _ in })
      #expect(!editor.isViewLoaded)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentViewController = editor
      window.orderFront(nil)
      defer { window.close() }
      window.contentView?.layoutSubtreeIfNeeded()
      let field = editor.masterFields[0]
      field.stringValue = "-12.04"
      field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
      field.controlTextDidChange(.init(name: NSControl.textDidChangeNotification))
      #expect(
        (service.workspacePreferences.landscapeProgramPreferences[100] ?? .init())
          .audioMasterVolumeDecibels
          == Ldtx_Workspace_V4_Rational32.with {
            $0.set(num: -120, den: 10)
          })
      #expect(service.selectedAudioMix == .landscape)
      service.workspacePreferences.landscapeProgramPreferences[100, default: .init()]
        .audioMasterVolumeDecibels = .with { $0.set(num: -60, den: 10) }
      for _ in 0..<50 {
        if field.stringValue == "-6" { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(field.stringValue == "-6")
      let previous = service.workspacePreferences
      field.stringValue = "invalid"
      field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
      #expect(field.dirty)
      #expect(service.workspacePreferences == previous)
    }

    @Test("UCT-1011.2: Monitor volume remains local without marking the Workspace edited")
    func monitorVolumeUsesAppletDataWithoutEditingDocument() throws {
      let suite = "MonitorVolume.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let data = WorkspaceAppletData(userDefaults: defaults)
      let document = WorkspaceDocument()
      defer { document.close() }
      let preferences = document.stateService.workspacePreferences
      _ = document.testCoordinator
      let url = try #require(document.stateService.localStateURL)
      data.updateState(for: url) { $0.monitorVolume = -12.5 }
      #expect(data.state(for: url).monitorVolume == -12.5)
      #expect(document.stateService.workspacePreferences == preferences)
      #expect(!document.hasTestModelChanges)
      let editor = MasterVolumeEditor(
        stateService: document.stateService, appletData: data, peakMeter: .init(),
        reportError: { _ in })
      #expect(editor.setMonitorVolume(-11.899999999999999))
      #expect(data.state(for: url).monitorVolume == -11.9)
      #expect(!editor.setMonitorVolume(.infinity))
      #expect(data.state(for: url).monitorVolume == -11.9)
      #expect(document.stateService.workspacePreferences == preferences)
      #expect(!document.hasTestModelChanges)
    }

  }
}
