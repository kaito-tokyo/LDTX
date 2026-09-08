// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Testing

@testable import LDTXProgramRuntime

struct ProgramOutputSharedH264ServiceTests {
  @Test func storesPayloadsInWorkspaceOwnedMemoryUntilAcknowledged() async throws {
    let service = try ProgramOutputSharedH264Service(slotCount: 1, slotSize: 64)
    let first = try await service.store([Data([1, 2, 3]), Data([4, 5])])

    #expect(first.slices.count == 2)
    #expect(first.slices[0].slot == 0)
    #expect(first.slices[0].generation == 1)
    #expect(first.slices[0].offset == 0)
    #expect(first.slices[1].offset == 3)

    let handle = try service.duplicatedReadHandle()
    #expect(fcntl(handle.fileDescriptor, F_GETFL) & O_ACCMODE == O_RDONLY)
    var bytes = [UInt8](repeating: 0, count: 5)
    #expect(pread(handle.fileDescriptor, &bytes, bytes.count, 0) == bytes.count)
    #expect(bytes == [1, 2, 3, 4, 5])

    await #expect(throws: ProgramOutputSharedH264MemoryError.exhausted) {
      try await service.store([Data([9])])
    }
    first.release()

    let second = try await service.store([Data([9])])
    #expect(second.slices[0].generation == 2)
    second.release()
  }

  @Test func rejectsBatchLargerThanOneSharedSlot() async throws {
    let service = try ProgramOutputSharedH264Service(slotCount: 1, slotSize: 4)
    await #expect(throws: ProgramOutputSharedH264MemoryError.packetBatchTooLarge(5)) {
      try await service.store([Data(repeating: 0, count: 5)])
    }
  }
}
