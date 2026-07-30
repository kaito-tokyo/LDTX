// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXOutputMedia
import Testing

@testable import LDTXRecordingXPCProtocol

struct RecordingAACSampleConverterTests {
  @Test func serializesSharedProgramAACWithoutPCMConversion() throws {
    let format = ProgramOutputAACFormat(
      sampleRate: 48_000,
      channelCount: 2,
      magicCookie: Data([0x12, 0x10])
    )
    let accessUnit = ProgramOutputAACAccessUnit(
      presentationTime: ProgramOutputMediaTime(value: 48_000, timescale: 48_000),
      duration: ProgramOutputMediaTime(value: 1_024, timescale: 48_000),
      sampleCount: 1,
      sampleSizes: [4],
      data: Data([1, 2, 3, 4])
    )

    let formatRecord = RecordingAACSampleConverter.formatRecord(from: format, sequence: 1)
    let accessUnitRecord = RecordingAACSampleConverter.accessUnitRecord(
      from: accessUnit,
      sequence: 2
    )

    #expect(formatRecord.format.sampleRate == 48_000)
    #expect(formatRecord.format.channelsPerFrame == 2)
    #expect(formatRecord.format.magicCookie == format.magicCookie)
    #expect(accessUnitRecord.accessUnit.presentationTime.value == 48_000)
    #expect(accessUnitRecord.accessUnit.duration.value == 1_024)
    #expect(accessUnitRecord.accessUnit.sampleSizes == [4])
    #expect(accessUnitRecord.accessUnit.data == accessUnit.data)
  }
}
