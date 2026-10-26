// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProgramRuntime
import LDTXProtos
@testable import LDTXWorkspaceAppletController
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1011: SwiftUI master volumes", .serialized) @MainActor
  struct UCT1011MasterVolumeEditorIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    struct VolumeInput: Sendable, Codable {
      let input: String
      let expectedNumerator: Int32
      let accepted: Bool
    }

    @Test(
      "LUB-1048: Master volume input commits tenths or preserves the accepted value",
      arguments: [
        VolumeInput(input: "-12.04", expectedNumerator: -120, accepted: true),
        VolumeInput(input: "-80", expectedNumerator: -800, accepted: true),
        VolumeInput(input: "20", expectedNumerator: 200, accepted: true),
        VolumeInput(input: "-", expectedNumerator: -120, accepted: false),
        VolumeInput(input: "100", expectedNumerator: -120, accepted: false),
        VolumeInput(input: "-81", expectedNumerator: -120, accepted: false),
        VolumeInput(input: "20.1", expectedNumerator: -120, accepted: false),
        VolumeInput(input: "inf", expectedNumerator: -120, accepted: false),
      ])
    func volumeInput(_ data: VolumeInput) async throws {
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.programs = [.with { $0.internalID = 100 }]
        workspace.preferences.landscapeProgramPreferences[100, default: .init()]
          .audioMasterVolumeDecibels.set(num: -120, den: 10)
      }
      let root = MasterVolumeEditor(
        stateService: state, appletData: WorkspaceAppletData(),
        peakMeter: StubAudioPeakMeter(), reportError: { _ in })
      let window = hostWorkspaceView(root)
      defer { window.close() }
      await settleWorkspaceToolbar(window)
      let field = try #require(
        workspaceDescendants(window.contentView!)
          .compactMap { $0 as? NSTextField }.first { $0.isEditable })
      let before = state.workspacePreferences
      try editWorkspaceField(field, text: data.input, window: window)
      await settleWorkspaceToolbar(window)
      #expect(
        state.workspacePreferences.landscapeProgramPreferences[100]?
          .audioMasterVolumeDecibels == .with { $0.set(num: data.expectedNumerator, den: 10) })
      if !data.accepted {
        #expect(state.workspacePreferences == before)
        #expect(field.currentEditor()?.string == data.input)
      }
      #expect(state.selectedAudioMix == .landscape)
    }

    @Test("LUB-1048: Injected program selection and model changes reach fields")
    func injectedProgramSelectionAndModelChangesReachFields() async throws {
      let suite = "SwiftUIMaster-\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let data = WorkspaceAppletData(userDefaults: defaults)
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      let url = URL(fileURLWithPath: "/tmp/SwiftUIMaster.ldtxworkspace")
      state.localStateURL = url
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.programs = [
          .with { $0.internalID = 100 }, .with { $0.internalID = 200 },
        ]
      }
      data.updateState(for: url) { $0.selectedProgramInternalID = 200 }
      let window = hostWorkspaceView(
        MasterVolumeEditor(
          stateService: state, appletData: data,
          peakMeter: StubAudioPeakMeter(), reportError: { _ in }))
      defer { window.close() }
      await settleWorkspaceToolbar(window)
      func firstField() throws -> NSTextField {
        try #require(
          workspaceDescendants(window.contentView!)
            .compactMap { $0 as? NSTextField }.first { $0.isEditable })
      }
      try editWorkspaceField(firstField(), text: "-12", window: window)
      await settleWorkspaceToolbar(window)
      #expect(
        state.workspacePreferences.landscapeProgramPreferences[200]?.audioMasterVolumeDecibels
          .double == -12)
      #expect(state.workspacePreferences.landscapeProgramPreferences[100] == nil)
      data.updateState(for: url) { $0.selectedProgramInternalID = 100 }
      await settleWorkspaceToolbar(window)
      try editWorkspaceField(firstField(), text: "-6", window: window)
      await settleWorkspaceToolbar(window)
      #expect(
        state.workspacePreferences.landscapeProgramPreferences[100]?.audioMasterVolumeDecibels
          .double == -6)
      window.makeFirstResponder(nil)
      await settleWorkspaceToolbar(window)
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.preferences.landscapeProgramPreferences[100, default: .init()]
          .audioMasterVolumeDecibels = .with { $0.set(num: -30, den: 10) }
      }
      await settleWorkspaceToolbar(window)
      #expect(try firstField().stringValue == "-3")
    }

    @Test("LUB-1048: Monitor volume stays local and rejects non finite values")
    func monitorVolumeStaysLocalAndRejectsNonFiniteValues() throws {
      let suite = "MonitorVolume-\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let data = WorkspaceAppletData(userDefaults: defaults)
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      let url = URL(fileURLWithPath: "/tmp/MonitorVolume.ldtxworkspace")
      state.localStateURL = url
      let before = state.editingWorkspace
      let editor = MasterVolumeEditor(
        stateService: state, appletData: data,
        peakMeter: StubAudioPeakMeter(), reportError: { _ in })
      #expect(editor.setMonitorVolume(-11.899999999999999))
      #expect(data.state(for: url).monitorVolume == -11.9)
      #expect(!editor.setMonitorVolume(.infinity))
      #expect(data.state(for: url).monitorVolume == -11.9)
      #expect(state.editingWorkspace == before)
    }
  }
}
