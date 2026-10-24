// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletStore
@testable import LDTXWorkspaceAppletUI
import Testing

extension OutputTestSuite {
  @Suite
  struct OutputSettingsModelUnitTestSuite {
    @Test("LUB-1066: Sdr1080p60 accepts positive canvas bit rates")
    func sdr1080p60AcceptsPositiveCanvasBitRates() {
      #expect(ProgramOutputConfiguration.sdr1080p60.isSupportedOutputProfile)
      var configuration = ProgramOutputConfiguration.sdr1080p60
      configuration.videoBitRate = 9_000_000
      #expect(configuration.isSupportedOutputProfile)
      configuration.videoBitRate = 0
      #expect(!configuration.isSupportedOutputProfile)
      configuration.videoBitRate = 9_000_000
      configuration.portraitVideoBitRate = 0
      #expect(!configuration.isSupportedOutputProfile)
    }

    @MainActor
    @Test("LUB-1066: All disabled destination is preserved for start time validation")
    func allDisabledDestinationIsPreservedForStartTimeValidation() {
      let model = OutputDestination(recordsLocally: false, streamsToYouTube: false)

      #expect(model.enabledCaptureOutputMode == nil)
      #expect(model.normalized() == model)
    }

    @Test("LUB-1066: Enabling output folder override requires a selected folder")
    func enablingOutputFolderOverrideRequiresASelectedFolder() {
      let original = OutputDestination(recordsLocally: true)

      #expect(
        OutputFolderOverrideSelection.applying(
          enabled: true,
          selectedURL: nil,
          to: original
        ) == nil)
    }

    @Test("LUB-1066: Output folder override selection and removal are atomic")
    func outputFolderOverrideSelectionAndRemovalAreAtomic() throws {
      let original = OutputDestination(recordsLocally: true)
      let selected = try #require(
        OutputFolderOverrideSelection.applying(
          enabled: true,
          selectedURL: URL(fileURLWithPath: "/tmp/old/../recordings", isDirectory: true),
          to: original
        ))

      #expect(selected.overridesOutputFolder)
      #expect(selected.outputFolderPath == "/tmp/recordings")

      let disabled = try #require(
        OutputFolderOverrideSelection.applying(
          enabled: false,
          selectedURL: nil,
          to: selected
        ))
      #expect(!disabled.overridesOutputFolder)
      #expect(disabled.outputFolderPath == nil)
    }

    @MainActor
    @Test("LUB-1066: Runtime service selection is derived from destination")
    func runtimeServiceSelectionIsDerivedFromDestination() {
      var model = OutputDestination(recordsLocally: true, streamsToYouTube: false)

      #expect(model.enabledCaptureOutputMode == .record)

      model.streamsToYouTube = true
      #expect(model.enabledCaptureOutputMode == .youtubeAndRecord)
    }
  }
}
