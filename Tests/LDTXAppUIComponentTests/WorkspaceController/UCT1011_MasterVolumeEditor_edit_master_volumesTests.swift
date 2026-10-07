// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXDeviceRegistry
import LDTXProtos
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletInterface
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

    @Test("UCT-1011.1: Master volume edits and model updates are reflected independently")
    func masterEditorObservesAndEditsVolumesIndependently() async throws {
      _ = NSApplication.shared
      let service = WorkspaceStoreService(definition: .init(), preferences: .init())
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 100
      service.definition.programs = [program]
      let editor = MasterVolumeEditor(storeService: service)
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
      field.commit()
      #expect(
        try service.preferences(for: 100, target: .landscape).audioMasterVolumeDecibels
          == Ldtx_Workspace_V4_Rational32.with {
            $0.set(num: -120, den: 10)
          })
      #expect(service.selectedAudioMix == .landscape)
      service.updateAudio(target: .landscape) {
        $0.audioMasterVolumeDecibels = .with {
          $0.numerator = -6
          $0.denominator = 1
        }
      }
      for _ in 0..<50 {
        if field.stringValue == "-6" { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(field.stringValue == "-6")
      let previous = service.preferences
      #expect(
        !service.updateAudio(target: .landscape) {
          $0.audioMasterVolumeDecibels = .with { $0.set(num: 1, den: 0) }
        })
      #expect(service.preferences == previous)
    }

    @Test("UCT-1011.2: Monitor volume remains local without marking the Workspace edited")
    func monitorVolumeUsesAppletDataWithoutEditingDocument() throws {
      let suite = "MonitorVolume.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let data = WorkspaceAppletData(userDefaults: defaults)
      let document = WorkspaceDocument()
      defer { document.close() }
      let preferences = document.storeService.preferences
      let url = try #require(document.storeService.localStateURL)
      data.updateState(for: url) { $0.monitorVolume = -12.5 }
      #expect(data.state(for: url).monitorVolume == -12.5)
      #expect(document.storeService.preferences == preferences)
      #expect(!document.isDocumentEdited)
      document.storeService.documentReference = DocumentReference(document)
      document.storeService.appletData = data
      document.storeService.updateMonitor { $0.monitorVolume = -11.899999999999999 }
      #expect(document.storeService.localState.monitorVolume == -11.9)
      document.storeService.updateMonitor { $0.monitorVolume = .infinity }
      #expect(document.storeService.localState.monitorVolume == -11.9)
      #expect(document.storeService.preferences == preferences)
      #expect(!document.isDocumentEdited)
    }

  }
}
