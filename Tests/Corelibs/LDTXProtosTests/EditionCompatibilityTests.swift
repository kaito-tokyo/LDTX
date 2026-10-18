// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import Testing

@Suite
struct EditionCompatibilityUnitTestSuite {
  @Test func clockFontSizeUsesNewTagAndPreservesReservedFieldsAsUnknown() throws {
    // Former width/height fields are no longer interpreted as Clock geometry.
    let legacy = Data([0x1a, 0x04, 0x08, 0x02, 0x10, 0x0c,
                       0x22, 0x04, 0x08, 0x04, 0x10, 0x36, 0x52, 0x00])
    var clock = try Ldtx_Workspace_V4_ClockComponent(serializedBytes: legacy)
    #expect(!clock.hasFontSize)
    #expect(clock.unknownFields.data == legacy)
    clock.fontSize.set(num: 48, den: 1)
    let restored = try Ldtx_Workspace_V4_ClockComponent(serializedBytes: clock.serializedData())
    #expect(restored.fontSize.double == 48)
    #expect(restored.unknownFields.data == legacy)
    #expect(try clock.serializedData().contains(0x62)) // field 12, length-delimited
  }
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
