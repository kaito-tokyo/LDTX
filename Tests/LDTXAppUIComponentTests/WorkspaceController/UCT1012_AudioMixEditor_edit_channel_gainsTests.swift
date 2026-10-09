// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXDeviceRegistry
import LDTXProgramRuntime
import LDTXProtos
@testable import LDTXWorkspaceAppletController
@testable import LDTXWorkspaceAppletUI
import LDTXYouTubeRTMPS
import Observation
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1012: edit-channel-gains", .serialized)
  @MainActor
  struct UCT1012AudioMixEditorIntegrationTestSuite {
    private static var controller: NSDocumentController {
      UIComponentTestEnvironment.documentController
    }
    init() { _ = Self.controller }

    @Test("UCT-1012.1: Channel gains can be edited without selecting a Program or canvas")
    func audioMixEditsWorkspaceGainWithoutCanvasOrProgramSelection() throws {
      _ = NSApplication.shared
      let service = WorkspaceStoreService(definition: .init(), preferences: .init())
      service.definition.audioDevices = [
        WorkspaceResourceFactory.makeAudioInput(id: 10, name: "Input")
      ]
      service.selectedAudioMix = .portrait
      let editor = AudioMixEditor(storeService: service)
      func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
      }
      let views = descendants(editor.view)
      #expect(!views.contains { $0 is NSSegmentedControl })
      let gains = views.compactMap { $0 as? AudioChannelControlView }
      #expect(gains.count == 1)
      let gain = try #require(gains.first)
      let slider = try #require(descendants(gain).compactMap { $0 as? NSSlider }.first)
      #expect(slider.isEnabled)
      slider.doubleValue = -12
      slider.sendAction(try #require(slider.action), to: slider.target)
      #expect(
        service.preferences.audioChannelGainsDecibels[10]
          == Ldtx_Workspace_V4_Rational32.with {
            $0.set(num: -120, den: 10)
          })
      #expect(!service.setAudioChannelGain(.nan, forAudioInputDeviceInternalID: 10))
      #expect(!service.setAudioChannelGain(-6, forAudioInputDeviceInternalID: 999))
      #expect(
        service.preferences.audioChannelGainsDecibels[10]
          == Ldtx_Workspace_V4_Rational32.with {
            $0.set(num: -120, den: 10)
          })
      #expect(service.selectedAudioMix == .portrait)
    }

    @Test("UCT-1012.2: Numeric gain drafts survive refresh and failed commit")
    func audioNumericDraftSurvivesRefreshAndFailure() {
      let field = AudioDecibelField()
      field.configure(
        value: .with {
          $0.numerator = 0
          $0.denominator = 1
        }, enabled: true
      ) { _ in false }
      field.stringValue = "-12.5"
      field.controlTextDidChange(
        Notification(name: NSControl.textDidChangeNotification, object: field))
      field.configure(
        value: .with {
          $0.numerator = -4
          $0.denominator = 1
        }, enabled: true
      ) { _ in false }
      #expect(field.stringValue == "-12.5")
      field.commit()
      #expect(field.dirty)
      var committed = 0.0
      field.configure(
        value: .with {
          $0.numerator = -4
          $0.denominator = 1
        }, enabled: true
      ) {
        committed = $0.double
        return true
      }
      field.commit()
      #expect(committed == -12.5)
      #expect(!field.dirty)
    }
  }
}
