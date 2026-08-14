// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspace
import XCTest

@testable import LDTXAppUI

final class OutputDestinationTests: XCTestCase {
  @MainActor
  func testCanvasStateDoesNotExposeAnEditableCBRBitRate() {
    let model = OutputCanvasModel()

    XCTAssertEqual(model.state, OutputCanvasModel().state)
  }

  func testSDR1080p60AcceptsPositiveCanvasBitRates() {
    XCTAssertTrue(WorkspaceOutputConfiguration.sdr1080p60.isSupportedOutputProfile)
    var configuration = WorkspaceOutputConfiguration.sdr1080p60
    configuration.videoBitRate = 9_000_000
    XCTAssertTrue(configuration.isSupportedOutputProfile)
    configuration.videoBitRate = 0
    XCTAssertFalse(configuration.isSupportedOutputProfile)
    configuration.videoBitRate = 9_000_000
    configuration.portraitVideoBitRate = 0
    XCTAssertFalse(configuration.isSupportedOutputProfile)
  }

  @MainActor
  func testAllDisabledDestinationIsPreservedForStartTimeValidation() {
    let model = OutputDestination(recordsLocally: false, streamsToYouTube: false)

    XCTAssertNil(model.enabledCaptureOutputMode)
    XCTAssertEqual(model.normalized(), model)
  }

  func testUnavailableOutputFolderIsPreservedForStartTimeValidation() {
    let model = OutputDestination(
      recordsLocally: true,
      streamsToYouTube: false,
      overridesOutputFolder: true,
      outputFolderPath: "/Volumes/Disconnected/Recordings")

    XCTAssertEqual(model.normalized(), model)
  }

  func testEnablingOutputFolderOverrideRequiresASelectedFolder() {
    let original = OutputDestination(recordsLocally: true)

    XCTAssertNil(
      OutputFolderOverrideSelection.applying(
        enabled: true,
        selectedURL: nil,
        to: original
      ))
  }

  func testOutputFolderOverrideSelectionAndRemovalAreAtomic() throws {
    let original = OutputDestination(recordsLocally: true)
    let selected = try XCTUnwrap(
      OutputFolderOverrideSelection.applying(
        enabled: true,
        selectedURL: URL(fileURLWithPath: "/tmp/old/../recordings", isDirectory: true),
        to: original
      ))

    XCTAssertTrue(selected.overridesOutputFolder)
    XCTAssertEqual(selected.outputFolderPath, "/tmp/recordings")

    let disabled = try XCTUnwrap(
      OutputFolderOverrideSelection.applying(
        enabled: false,
        selectedURL: nil,
        to: selected
      ))
    XCTAssertFalse(disabled.overridesOutputFolder)
    XCTAssertNil(disabled.outputFolderPath)
  }

  @MainActor
  func testRuntimeServiceSelectionIsDerivedFromDestination() {
    var model = OutputDestination(recordsLocally: true, streamsToYouTube: false)

    XCTAssertEqual(model.enabledCaptureOutputMode, .record)

    model.streamsToYouTube = true
    XCTAssertEqual(model.enabledCaptureOutputMode, .youtubeAndRecord)
  }
}
