// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@testable import LDTX
import LDTXAppUI
import Testing

struct RecordingSplitAutomationSupportTests {
  @Test func rejectsSplitWhileStreamingWithoutRecording() {
    let result = RecordingSplitAutomationSupport.validationFailure(
      isOutputSessionRunning: true,
      activeCaptureOutputMode: .youtube
    )

    #expect(result?.message == "Recording split is only available for record or youtubeAndRecord output.")
    #expect(result?.ok == false)
  }

  @Test func allowsSplitForYouTubeAndRecord() {
    let result = RecordingSplitAutomationSupport.validationFailure(
      isOutputSessionRunning: true,
      activeCaptureOutputMode: .youtubeAndRecord
    )

    #expect(result == nil)
  }
}
