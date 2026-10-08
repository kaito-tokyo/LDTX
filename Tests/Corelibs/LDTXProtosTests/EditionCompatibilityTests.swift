// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import Testing

@Suite
struct EditionCompatibilityUnitTestSuite {
  @Test func preservesExplicitFalseForRecordingEnabled() throws {
    var output = Ldtx_Workspace_V4_WorkspaceOutputSettingsV4()
    #expect(!output.hasRecordingEnabled)
    #expect(try output.serializedData().isEmpty)
    output.recordingEnabled = false
    let bytes = Data([0x08, 0x00])
    #expect(try output.serializedData() == bytes)
    let restored = try Ldtx_Workspace_V4_WorkspaceOutputSettingsV4(serializedBytes: bytes)
    #expect(restored.hasRecordingEnabled)
    #expect(!restored.recordingEnabled)
    output.clearRecordingEnabled()
    #expect(try output.serializedData().isEmpty)
  }

  @Test func preservesExplicitZeroAndClearForClockOffset() throws {
    var clock = Ldtx_Workspace_V4_ClockComponent()
    #expect(!clock.hasUtcOffsetMinutes)
    clock.utcOffsetMinutes = 0
    let bytes = Data([0x40, 0x00])
    #expect(try clock.serializedData() == bytes)
    let restored = try Ldtx_Workspace_V4_ClockComponent(serializedBytes: bytes)
    #expect(restored.hasUtcOffsetMinutes)
    #expect(restored.utcOffsetMinutes == 0)
    clock.clearUtcOffsetMinutes()
    #expect(try clock.serializedData().isEmpty)
  }

  @Test func preservesExplicitZeroInYouTubeReplies() throws {
    var reply = Ldtx_YoutubeOutput_V1_Reply()
    reply.sequence = 0
    let bytes = Data([0x10, 0x00])
    #expect(try reply.serializedData() == bytes)
    let restored = try Ldtx_YoutubeOutput_V1_Reply(serializedBytes: bytes)
    #expect(restored.hasSequence)
    #expect(restored.sequence == 0)
    reply.clearSequence()
    #expect(try reply.serializedData().isEmpty)
  }
}
