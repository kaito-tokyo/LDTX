// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspace
import Testing

@testable import LDTXApp

@Suite
struct OutputSettingsModelUnitTestSuite {
  @MainActor
  @Test func canvasStateDoesNotExposeAnEditableCBRBitRate() {
    let model = OutputCanvasModel()

    #expect(model.state == OutputCanvasModel().state)
  }

  @Test func sdr1080p60AcceptsPositiveCanvasBitRates() {
    #expect(WorkspaceOutputConfiguration.sdr1080p60.isSupportedOutputProfile)
    var configuration = WorkspaceOutputConfiguration.sdr1080p60
    configuration.videoBitRate = 9_000_000
    #expect(configuration.isSupportedOutputProfile)
    configuration.videoBitRate = 0
    #expect(!configuration.isSupportedOutputProfile)
    configuration.videoBitRate = 9_000_000
    configuration.portraitVideoBitRate = 0
    #expect(!configuration.isSupportedOutputProfile)
  }

  @MainActor
  @Test func allDisabledDestinationIsPreservedForStartTimeValidation() {
    let model = OutputDestination(recordsLocally: false, streamsToYouTube: false)

    #expect(model.enabledCaptureOutputMode == nil)
    #expect(model.normalized() == model)
  }

  @Test func unavailableOutputFolderIsPreservedForStartTimeValidation() {
    let model = OutputDestination(
      recordsLocally: true,
      streamsToYouTube: false,
      overridesOutputFolder: true,
      outputFolderPath: "/Volumes/Disconnected/Recordings")

    #expect(model.normalized() == model)
  }

  @Test func enablingOutputFolderOverrideRequiresASelectedFolder() {
    let original = OutputDestination(recordsLocally: true)

    #expect(
      OutputFolderOverrideSelection.applying(
        enabled: true,
        selectedURL: nil,
        to: original
      ) == nil)
  }

  @Test func outputFolderOverrideSelectionAndRemovalAreAtomic() throws {
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
  @Test func runtimeServiceSelectionIsDerivedFromDestination() {
    var model = OutputDestination(recordsLocally: true, streamsToYouTube: false)

    #expect(model.enabledCaptureOutputMode == .record)

    model.streamsToYouTube = true
    #expect(model.enabledCaptureOutputMode == .youtubeAndRecord)
  }
}
