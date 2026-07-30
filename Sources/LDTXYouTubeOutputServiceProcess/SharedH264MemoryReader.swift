// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import LDTXYouTubeOutputProtocol

enum SharedH264MemoryReaderError: Error, LocalizedError {
  case invalidLayout
  case cannotMap(Int32)
  case invalidSlice
  case staleGeneration

  var errorDescription: String? {
    switch self {
    case .invalidLayout: "The shared H.264 memory layout is invalid."
    case .cannotMap(let code): "Could not map shared H.264 memory (errno \(code))."
    case .invalidSlice: "The shared H.264 packet descriptor is outside its slot."
    case .staleGeneration: "The shared H.264 packet descriptor has a stale generation."
    }
  }
}

/// Read-only view of Workspace-owned H.264 storage for one XPC session.
final class SharedH264MemoryReader: @unchecked Sendable {
  private let address: UnsafeRawPointer
  private let byteCount: Int
  private let slotCount: Int
  private let slotSize: Int
  private var generations: [UInt64]

  init(handle: FileHandle, slotCount: Int, slotSize: Int) throws {
    guard slotCount > 0, slotSize > 0, slotCount <= Int.max / slotSize else {
      throw SharedH264MemoryReaderError.invalidLayout
    }
    let byteCount = slotCount * slotSize
    var status = stat()
    guard fstat(handle.fileDescriptor, &status) == 0, status.st_size >= byteCount else {
      throw SharedH264MemoryReaderError.invalidLayout
    }
    let mapping = mmap(nil, byteCount, PROT_READ, MAP_SHARED, handle.fileDescriptor, 0)
    guard mapping != MAP_FAILED, let mapping else {
      throw SharedH264MemoryReaderError.cannotMap(errno)
    }
    address = UnsafeRawPointer(mapping)
    self.byteCount = byteCount
    self.slotCount = slotCount
    self.slotSize = slotSize
    generations = Array(repeating: 0, count: slotCount)
  }

  deinit { munmap(UnsafeMutableRawPointer(mutating: address), byteCount) }

  func read(_ slice: YouTubeOutputSharedMemorySlice) throws -> Data {
    guard slice.slot >= 0, slice.slot < slotCount,
      slice.generation > 0,
      slice.offset >= 0, slice.length >= 0,
      slice.offset <= slotSize,
      slice.length <= slotSize - slice.offset
    else { throw SharedH264MemoryReaderError.invalidSlice }
    guard slice.generation >= generations[slice.slot] else {
      throw SharedH264MemoryReaderError.staleGeneration
    }
    generations[slice.slot] = slice.generation
    return Data(
      bytes: address.advanced(by: slice.slot * slotSize + slice.offset),
      count: slice.length)
  }
}
