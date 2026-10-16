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

    @Test func writesOnChangeAndPreservesInvalidDrafts() async throws {
      let state = WorkspaceStateService(definition: .init(), preferences: .init())
      state.workspaceDefinition.programs = [.with { $0.internalID = 100 }]
      let root = MasterVolumeEditor(
        stateService: state, appletData: WorkspaceAppletData(),
        peakMeter: .init(), reportError: { _ in })
      let window = hostWorkspaceView(root)
      defer { window.close() }
      await settleWorkspaceToolbar(window)
      let field = try #require(
        workspaceDescendants(window.contentView!)
          .compactMap { $0 as? NSTextField }.first { $0.isEditable })
      try editWorkspaceField(field, text: "-12.04", window: window)
      await settleWorkspaceToolbar(window)
      #expect(
        state.workspacePreferences.landscapeProgramPreferences[100]?
          .audioMasterVolumeDecibels == .with { $0.set(num: -120, den: 10) })
      let before = state.workspacePreferences
      for text in ["-", "100", "-81", "20.1", "inf"] {
        try editWorkspaceField(field, text: text, window: window)
        await settleWorkspaceToolbar(window)
        #expect(state.workspacePreferences == before)
        #expect(field.currentEditor()?.string == text)
      }
      for text in ["-80", "20"] {
        try editWorkspaceField(field, text: text, window: window)
        await settleWorkspaceToolbar(window)
        #expect(
          state.workspacePreferences.landscapeProgramPreferences[100]?
            .audioMasterVolumeDecibels.double == Double(text))
      }
      #expect(state.selectedAudioMix == .landscape)
    }

    @Test func injectedProgramSelectionAndModelChangesReachFields() async throws {
      let suite = "SwiftUIMaster-\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let data = WorkspaceAppletData(userDefaults: defaults)
      let state = WorkspaceStateService(definition: .init(), preferences: .init())
      let url = URL(fileURLWithPath: "/tmp/SwiftUIMaster.ldtxworkspace")
      state.localStateURL = url
      state.workspaceDefinition.programs = [
        .with { $0.internalID = 100 }, .with { $0.internalID = 200 },
      ]
      data.updateState(for: url) { $0.selectedProgramInternalID = 200 }
      let window = hostWorkspaceView(
        MasterVolumeEditor(
          stateService: state, appletData: data,
          peakMeter: .init(), reportError: { _ in }))
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
      state.workspacePreferences.landscapeProgramPreferences[100, default: .init()]
        .audioMasterVolumeDecibels = .with { $0.set(num: -30, den: 10) }
      await settleWorkspaceToolbar(window)
      #expect(try firstField().stringValue == "-3")
    }

    @Test func monitorVolumeStaysLocalAndRejectsNonFiniteValues() throws {
      let suite = "MonitorVolume-\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let data = WorkspaceAppletData(userDefaults: defaults)
      let state = WorkspaceStateService(definition: .init(), preferences: .init())
      let url = URL(fileURLWithPath: "/tmp/MonitorVolume.ldtxworkspace")
      state.localStateURL = url
      let before = state.editingWorkspace
      let editor = MasterVolumeEditor(
        stateService: state, appletData: data,
        peakMeter: .init(), reportError: { _ in })
      #expect(editor.setMonitorVolume(-11.899999999999999))
      #expect(data.state(for: url).monitorVolume == -11.9)
      #expect(!editor.setMonitorVolume(.infinity))
      #expect(data.state(for: url).monitorVolume == -11.9)
      #expect(state.editingWorkspace == before)
    }
  }
}
