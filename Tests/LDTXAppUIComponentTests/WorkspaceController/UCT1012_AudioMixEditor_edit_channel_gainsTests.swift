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
    @Test("LUB-1048: Gain edits do not require program or canvas selection")
    func gainEditsDoNotRequireProgramOrCanvasSelection() throws {
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.audioDevices = [
          WorkspaceResourceFactory.makeAudioInput(id: 10, name: "Input")
        ]
      }
      state.selectedAudioMix = .portrait
      let editor = AudioMixEditor(
        stateService: state, appletData: WorkspaceAppletData(),
        peakMeter: StubAudioPeakMeter(), reportError: { _ in })
      #expect(editor.setAudioChannelGain(-12, forAudioInputDeviceInternalID: 10))
      let saved = state.workspacePreferences
      #expect(saved.audioChannelGainsDecibels[10] == .with { $0.set(num: -120, den: 10) })
      #expect(!editor.setAudioChannelGain(.nan, forAudioInputDeviceInternalID: 10))
      #expect(!editor.setAudioChannelGain(-6, forAudioInputDeviceInternalID: 999))
      #expect(state.workspacePreferences == saved)
      #expect(state.selectedAudioMix == .portrait)
    }
    @Test("LUB-1048: Hosted mixer updates when devices change")
    func hostedMixerUpdatesWhenDevicesChange() async throws {
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      let editor = AudioMixEditor(
        stateService: state, appletData: WorkspaceAppletData(),
        peakMeter: StubAudioPeakMeter(), reportError: { _ in })
      let window = hostWorkspaceView(editor)
      defer { window.close() }
      let host = try #require(window.contentViewController as? NSHostingController<AudioMixEditor>)
      let proposal = NSSize(width: 720, height: CGFloat.greatestFiniteMagnitude)
      let emptyHeight = host.sizeThatFits(in: proposal).height
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.audioDevices = [
          WorkspaceResourceFactory.makeAudioInput(id: 10, name: "Input")
        ]
      }
      await settleWorkspaceToolbar(window)
      #expect(host.sizeThatFits(in: proposal).height > emptyHeight)
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.audioDevices = []
      }
      await settleWorkspaceToolbar(window)
      #expect(abs(host.sizeThatFits(in: proposal).height - emptyHeight) < 1)
    }
  }
}
