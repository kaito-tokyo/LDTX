// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import Testing

@Suite
struct NanopbCodecUnitTestSuite {
  @Test("Official callbacks handle large variable-length payloads and oneof replacement")
  func callbackPayloads() throws {
    let text = String(repeating: "日本語🍎", count: 80_000)
    let original = Ldtx_Workspace_V4_OcrVision.with {
      $0.displayName = text
      $0.customWords = (0..<1_000).map { "word-\($0)" }
      $0.recognitionLanguages = ["ja-JP", "en-US"]
    }
    #expect(try Ldtx_Workspace_V4_OcrVision(serializedBytes: original.serializedData()) == original)

    let first = Ldtx_Workspace_V4_VisionWrapper.with { $0.ocrVision = original }
    let other = Ldtx_Workspace_V4_VisionWrapper.with {
      $0.ldtxSceneDetectorVision.displayName = "other"
    }
    let last = Ldtx_Workspace_V4_VisionWrapper.with { $0.ocrVision.displayName = "last" }
    let bytes = try first.serializedData() + other.serializedData() + last.serializedData()
    let result = try Ldtx_Workspace_V4_VisionWrapper(serializedBytes: bytes)
    #expect(result == last)
  }

  @Test("String fields decode directly, including NUL and long UTF-8")
  func strings() throws {
    for text in ["", "a\0b", "日本語🍎", String(repeating: "あ", count: 100)] {
      let original = Ldtx_Workspace_V4_ProgramDefinition.with { $0.displayName = text }
      let decoded = try Ldtx_Workspace_V4_ProgramDefinition(
        serializedBytes: original.serializedData())
      #expect(decoded == original)
      #expect(decoded.hasDisplayName)
    }
  }

  @Test("Rejects invalid UTF-8, tags, wire types and truncated fields")
  func malformed() throws {
    let inputs: [[UInt8]] = [
      [0x12, 1, 0xff], [0x12, 2, 0xc0, 0x80], [0x12, 1, 0xc2],
      [0x12, 3, 0xed, 0xa0, 0x80], [0x12, 4, 0xf4, 0x90, 0x80, 0x80],
      [0x12, 2, 0, 0xff],  // Invalid UTF-8 after an embedded NUL must also fail.
      [0], [0x10, 1], [0x12, 5, 0x41],
    ]
    for input in inputs {
      #expect(throws: (any Error).self) {
        _ = try Ldtx_Workspace_V4_ProgramDefinition(serializedBytes: input)
      }
    }
  }

  @Test("nanopb handles Bool and rejects overflowing uint32 fields")
  func scalarDecoders() throws {
    let settings = try Ldtx_Workspace_V4_WorkspaceOutputSettingsV4(
      serializedBytes: Data([8, 2]))
    #expect(settings.recordingEnabled)
    #expect(throws: (any Error).self) {
      _ = try Ldtx_Workspace_V4_Rational32(
        serializedBytes: Data([16, 0x80, 0x80, 0x80, 0x80, 0x10]))
    }
  }

  @Test("Known protobuf fixtures preserve explicit default presence")
  func wireFixture() throws {
    let rational = try Ldtx_Workspace_V4_Rational32(
      serializedBytes: [UInt8](arrayLiteral: 8, 3, 16, 7))
    #expect(rational.num == -2)
    #expect(rational.den == 7)
    #expect(try rational.serializedData() == Data([8, 3, 16, 7]))
    let zero = try Ldtx_Workspace_V4_Rational32(serializedBytes: [UInt8](arrayLiteral: 8, 0))
    #expect(zero.hasNum)
    #expect(!zero.hasDen)
    #expect(zero.den == 1)
  }

  @Test("Nested messages merge repeated occurrences")
  func mergeMessages() throws {
    // Clock.font_size: first num=48, then den=2.
    let value = try Ldtx_Workspace_V4_ClockComponent(
      serializedBytes:
        Data([0x62, 2, 8, 96, 0x62, 2, 16, 2]))
    #expect(value.fontSize.num == 48)
    #expect(value.fontSize.den == 2)
  }

  @Test("Packed fixed64 and unpacked fields decode equivalently")
  func packed() throws {
    let packed = Data([0x1a, 16, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0])
    let value = try Ldtx_Workspace_V4_ProgramPreferences(serializedBytes: packed)
    #expect(value.videoLayerInternalIds == [1, 2])
    #expect(
      try Ldtx_Workspace_V4_ProgramPreferences(serializedBytes: value.serializedData()) == value)
  }

  @Test("Maps serialize deterministically regardless of insertion order")
  func deterministicMaps() throws {
    // Exercise schema map entries directly through the shared preferences model.
    var a = Ldtx_Workspace_V4_ProgramPreferences()
    var b = Ldtx_Workspace_V4_ProgramPreferences()
    a.audioChannelMuted[9] = true
    a.audioChannelMuted[1] = false
    b.audioChannelMuted[1] = false
    b.audioChannelMuted[9] = true
    #expect(try a.serializedData() == b.serializedData())
    #expect(try Ldtx_Workspace_V4_ProgramPreferences(serializedBytes: a.serializedData()) == a)
  }

  @Test("ProtoJSON retains int64 precision, enums, bytes and presence")
  func jsonRoundTrip() throws {
    let original = Ldtx_Workspace_V4_ProgramDefinition.with {
      $0.internalID = Int64.max
      $0.displayName = "日本語"
    }
    let json = try original.jsonUTF8Data()
    #expect(String(decoding: json, as: UTF8.self).contains("9223372036854775807"))
    #expect(try Ldtx_Workspace_V4_ProgramDefinition(jsonUTF8Data: json) == original)
    let color = Ldtx_Workspace_V4_Color.with {
      $0.red = 1.25
      $0.alpha = 1
    }
    #expect(try Ldtx_Workspace_V4_Color(jsonUTF8Data: color.jsonUTF8Data()) == color)
    let output = Ldtx_Workspace_V4_YouTubeOutputSettings.with { $0.ingestMode = .dualRtmps }
    #expect(
      try Ldtx_Workspace_V4_YouTubeOutputSettings(jsonUTF8Data: output.jsonUTF8Data()) == output)
    let envelope = Ldtx_Envelope_WorkspaceDefinitionEnvelope.with {
      $0.externalID = Data([0, 0xff, 7])
    }
    #expect(
      try Ldtx_Envelope_WorkspaceDefinitionEnvelope(jsonUTF8Data: envelope.jsonUTF8Data())
        == envelope)
  }
}
