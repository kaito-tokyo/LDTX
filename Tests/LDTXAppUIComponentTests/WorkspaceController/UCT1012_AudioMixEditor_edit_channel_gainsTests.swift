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
  @Suite("UCT-1012: SwiftUI channel gains", .serialized) @MainActor
  struct UCT1012AudioMixEditorIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }
    @Test func gainEditsDoNotRequireProgramOrCanvasSelection() throws {
      let state = WorkspaceStateService(definition: .init(), preferences: .init())
      state.workspaceDefinition.audioDevices = [
        WorkspaceResourceFactory.makeAudioInput(id: 10, name: "Input")
      ]
      state.selectedAudioMix = .portrait
      let editor = AudioMixEditor(
        stateService: state, appletData: WorkspaceAppletData(),
        peakMeter: .init(), reportError: { _ in })
      #expect(editor.setAudioChannelGain(-12, forAudioInputDeviceInternalID: 10))
      let saved = state.workspacePreferences
      #expect(saved.audioChannelGainsDecibels[10] == .with { $0.set(num: -120, den: 10) })
      #expect(!editor.setAudioChannelGain(.nan, forAudioInputDeviceInternalID: 10))
      #expect(!editor.setAudioChannelGain(-6, forAudioInputDeviceInternalID: 999))
      #expect(state.workspacePreferences == saved)
      #expect(state.selectedAudioMix == .portrait)
    }
    @Test func hostedMixerUpdatesWhenDevicesChange() async throws {
      let state = WorkspaceStateService(definition: .init(), preferences: .init())
      let editor = AudioMixEditor(
        stateService: state, appletData: WorkspaceAppletData(),
        peakMeter: .init(), reportError: { _ in })
      let window = hostWorkspaceView(editor)
      defer { window.close() }
      state.workspaceDefinition.audioDevices = [
        WorkspaceResourceFactory.makeAudioInput(id: 10, name: "Input")
      ]
      await settleWorkspaceToolbar(window)
      #expect(workspaceDescendants(window.contentView!).contains { $0 is AudioPeakMeterMTKView })
      state.workspaceDefinition.audioDevices = []
      await settleWorkspaceToolbar(window)
      #expect(!workspaceDescendants(window.contentView!).contains { $0 is AudioPeakMeterMTKView })
    }
  }
}
