// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXRecordPlayerUI
import SwiftUI

struct RecordingPreviewScene: View {
  @Environment(\.dismissWindow) private var dismissWindow

  private let recordingURL: URL
  private let scenarioFixture: RecordingPreviewScenarioFixture?

  init(
    recordingURL: URL,
    scenarioFixture: RecordingPreviewScenarioFixture? = nil
  ) {
    self.recordingURL = recordingURL
    self.scenarioFixture = scenarioFixture
  }

  var body: some View {
    LDTXRecordPlayerView(
      recordingURL: recordingURL,
      scenarioFixture: scenarioFixture,
      closePreview: {
        dismissWindow(id: "recording-preview", value: recordingURL)
      }
    )
    .navigationTitle(recordingURL.deletingPathExtension().lastPathComponent)
  }
}
