// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import LDTXTaskQueue
import LDTXYouTubeOutputProtocol

enum ProgramOutputSharedH264MemoryError: Error, Equatable, LocalizedError {
  case cannotCreate(Int32)
  case cannotResize(Int32)
  case cannotMap(Int32)
  case packetBatchTooLarge(Int)
  case exhausted

  var errorDescription: String? {
    switch self {
    case .cannotCreate(let code): "Could not create shared H.264 memory (errno \(code))."
    case .cannotResize(let code): "Could not size shared H.264 memory (errno \(code))."
    case .cannotMap(let code): "Could not map shared H.264 memory (errno \(code))."
    case .packetBatchTooLarge(let size):
      "The encoded H.264 batch is too large for shared memory (\(size) bytes)."
    case .exhausted: "All shared H.264 memory slots are awaiting consumer acknowledgement."
    }
  }
}

/// Workspace-owned storage for encoded H.264 payloads consumed by an XPC
/// Service Process. The App is the only writer. A Service Process receives a
/// duplicated descriptor and maps it read-only for one Output Session.
public final class ProgramOutputSharedH264Service: @unchecked Sendable {
  public static let defaultSlotCount = 8
  public static let defaultSlotSize = 16 * 1_024 * 1_024

  struct StoredBatch: @unchecked Sendable {
    var slices: [YouTubeOutputSharedMemorySlice]
    fileprivate let lease: Lease

    func release() { lease.release() }
  }

  fileprivate final class Lease: @unchecked Sendable {
    private let releaseBody: @Sendable () -> Void

    init(release: @escaping @Sendable () -> Void) { releaseBody = release }

    func release() { releaseBody() }

    deinit { releaseBody() }
  }

  private enum ResourceTask: @unchecked Sendable {
    case store([Data], CheckedContinuation<Result<StoredBatch, Error>, Never>)
    case release(slot: Int, generation: UInt64)
  }

  let slotCount: Int
  let slotSize: Int

  private let descriptor: Int32
  private let readDescriptor: Int32
  private let address: UnsafeMutableRawPointer
  private let byteCount: Int
  private var occupied: [Bool]
  private var generations: [UInt64]
  private lazy var taskQueue = ResourceTaskQueue<ResourceTask>(
    label: "tokyo.kaito.ldtx.shared-h264-resource", logger: .disabled
  ) { [weak self] task, _, _ in
    self?.execute(task)
  }

  public init(
    slotCount: Int = ProgramOutputSharedH264Service.defaultSlotCount,
    slotSize: Int = ProgramOutputSharedH264Service.defaultSlotSize
  ) throws {
    precondition(slotCount > 0 && slotSize > 0)
    self.slotCount = slotCount
    self.slotSize = slotSize
    byteCount = slotCount * slotSize
    occupied = Array(repeating: false, count: slotCount)
    generations = Array(repeating: 0, count: slotCount)

    var template = Array("/tmp/ldtx-h264-XXXXXX".utf8CString)
    let descriptor = mkstemp(&template)
    guard descriptor >= 0 else { throw ProgramOutputSharedH264MemoryError.cannotCreate(errno) }
    guard ftruncate(descriptor, off_t(byteCount)) == 0 else {
      let code = errno
      unlink(template)
      close(descriptor)
      throw ProgramOutputSharedH264MemoryError.cannotResize(code)
    }
    let readDescriptor = open(template, O_RDONLY)
    let readOpenError = errno
    unlink(template)
    guard readDescriptor >= 0 else {
      close(descriptor)
      throw ProgramOutputSharedH264MemoryError.cannotCreate(readOpenError)
    }
    self.descriptor = descriptor
    self.readDescriptor = readDescriptor
    let mapping = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0)
    guard mapping != MAP_FAILED, let mapping else {
      let code = errno
      close(readDescriptor)
      close(descriptor)
      throw ProgramOutputSharedH264MemoryError.cannotMap(code)
    }
    address = mapping
  }

  deinit {
    munmap(address, byteCount)
    close(readDescriptor)
    close(descriptor)
  }

  func duplicatedReadHandle() throws -> FileHandle {
    let duplicated = dup(readDescriptor)
    guard duplicated >= 0 else { throw ProgramOutputSharedH264MemoryError.cannotCreate(errno) }
    return FileHandle(fileDescriptor: duplicated, closeOnDealloc: true)
  }

  func store(_ payloads: [Data]) async throws -> StoredBatch {
    let result = await withCheckedContinuation { continuation in
      guard taskQueue.post(.store(payloads, continuation)) else {
        continuation.resume(returning: .failure(CancellationError()))
        return
      }
    }
    return try result.get()
  }

  private func execute(_ task: ResourceTask) {
    switch task {
    case .store(let payloads, let continuation):
      do {
        continuation.resume(returning: .success(try storeOnResourceQueue(payloads)))
      } catch {
        continuation.resume(returning: .failure(error))
      }
    case .release(let slot, let generation):
      guard generations[slot] == generation else { return }
      occupied[slot] = false
    }
  }

  private func storeOnResourceQueue(_ payloads: [Data]) throws -> StoredBatch {
    let totalSize = payloads.reduce(0) { $0 + $1.count }
    guard totalSize <= slotSize else {
      throw ProgramOutputSharedH264MemoryError.packetBatchTooLarge(totalSize)
    }
    guard let slot = occupied.firstIndex(of: false) else {
      throw ProgramOutputSharedH264MemoryError.exhausted
    }
    occupied[slot] = true
    generations[slot] &+= 1
    let allocation = (slot: slot, generation: generations[slot])

    var offset = 0
    var slices: [YouTubeOutputSharedMemorySlice] = []
    slices.reserveCapacity(payloads.count)
    for payload in payloads {
      payload.withUnsafeBytes { bytes in
        guard let source = bytes.baseAddress, !payload.isEmpty else { return }
        address.advanced(by: allocation.slot * slotSize + offset)
          .copyMemory(from: source, byteCount: payload.count)
      }
      slices.append(
        YouTubeOutputSharedMemorySlice(
          slot: allocation.slot,
          generation: allocation.generation,
          offset: offset,
          length: payload.count))
      offset += payload.count
    }
    let lease = Lease { [weak self] in
      self?.taskQueue.post(.release(slot: allocation.slot, generation: allocation.generation))
    }
    return StoredBatch(slices: slices, lease: lease)
  }
}
