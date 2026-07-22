// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import Testing

@testable import LDTXProgramRuntime

struct ActiveProgramPreferencesTests {
  @Test func muteUpdatesDoNotRebuildTheVideoInputPipeline() throws {
    let renderer = ActiveProgramRenderer(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator()
    )
    let initialPipelineID = try #require(renderer.videoPipelineIDForTesting)

    renderer.updateProgramPreferences(
      ProgramPreferences(videoMutedByInputDeviceName: ["Camera": true])
    )
    #expect(renderer.videoPipelineIDForTesting == initialPipelineID)

    renderer.updateProgramPreferences(
      ProgramPreferences(videoMutedByInputDeviceName: ["Camera": false])
    )
    #expect(renderer.videoPipelineIDForTesting == initialPipelineID)
  }
}
