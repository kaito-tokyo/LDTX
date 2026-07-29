// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftProtobuf
import Testing

@testable import LDTXRecordingXPCProtocol

struct RecordingSharedRingTests {
  @Test func transfersRecordsThroughSharedMapping() throws {
    let producer = try RecordingSharedRingProducer.create(capacity: 4_096)
    let consumer = try RecordingSharedRingConsumer(descriptor: producer.descriptor)

    #expect(producer.write(Data("video".utf8)))
    #expect(producer.write(Data("audio".utf8)))
    #expect(consumer.read() == Data("video".utf8))
    #expect(consumer.read() == Data("audio".utf8))
    #expect(consumer.read() == nil)
  }

  @Test func wrapsWithoutReorderingRecords() throws {
    let producer = try RecordingSharedRingProducer.create(capacity: 4_096)
    let consumer = try RecordingSharedRingConsumer(descriptor: producer.descriptor)
    let records = (0..<80).map { index in
      Data(repeating: UInt8(index), count: 73)
    }

    for chunk in records.chunks(ofCount: 20) {
      for record in chunk { #expect(producer.write(record)) }
      for record in chunk { #expect(consumer.read() == record) }
    }
  }

  @Test func rejectsOverflowWithoutOverwritingUnreadData() throws {
    let producer = try RecordingSharedRingProducer.create(capacity: 4_096)
    let consumer = try RecordingSharedRingConsumer(descriptor: producer.descriptor)
    let first = Data(repeating: 0xA5, count: 3_000)
    let overflow = Data(repeating: 0x5A, count: 1_500)

    #expect(producer.write(first))
    #expect(!producer.write(overflow))
    #expect(consumer.read() == first)
    #expect(consumer.read() == nil)
  }

  @Test func protobufControlCarriesProtocolVersion() throws {
    var request = Ldtx_Recording_Xpc_V1_ConfigureRequest()
    request.protocolVersion = LDTXRecordingWriterXPCInterfaces.protocolVersion
    request.trackID = "output-video"
    request.ringCapacity = 16 * 1_024 * 1_024

    let decoded = try Ldtx_Recording_Xpc_V1_ConfigureRequest(
      serializedBytes: request.serializedData()
    )
    #expect(decoded.protocolVersion == 2)
    #expect(decoded.trackID == "output-video")
  }

  @Test func fragmentKindRoundTripsIndependentlyFromDuration() throws {
    var event = Ldtx_Recording_Xpc_V1_Event()
    event.kind = .fragmentCommitted
    event.fragmentKind = .media

    let decoded = try Ldtx_Recording_Xpc_V1_Event(serializedBytes: event.serializedData())
    #expect(decoded.fragmentKind == .media)
    #expect(decoded.durationTimescale == 0)
  }
}

extension Array {
  fileprivate func chunks(ofCount count: Int) -> [[Element]] {
    stride(from: 0, to: self.count, by: count).map {
      Array(self[$0..<Swift.min($0 + count, self.count)])
    }
  }
}
