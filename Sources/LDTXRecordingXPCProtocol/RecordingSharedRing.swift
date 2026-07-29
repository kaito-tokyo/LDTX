// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import LDTXRecordingSharedRingC

public enum RecordingSharedRingError: Error, Equatable {
  case invalidCapacity(Int)
  case cannotCreateBackingFile(Int32)
  case cannotResizeBackingFile(Int32)
  case cannotMapBackingFile(Int32)
  case incompatibleDescriptor
}

public final class RecordingSharedRingDescriptor: @unchecked Sendable {
  public let fileHandle: FileHandle
  public let capacity: Int
  public let protocolVersion: UInt64

  public init(fileHandle: FileHandle, capacity: Int, protocolVersion: UInt64) {
    self.fileHandle = fileHandle
    self.capacity = capacity
    self.protocolVersion = protocolVersion
  }
}

public final class RecordingSharedRingProducer: @unchecked Sendable {
  public static let protocolVersion: UInt64 = 1

  public let descriptor: RecordingSharedRingDescriptor
  private let storage: RecordingSharedRingStorage

  public static func create(capacity: Int) throws -> RecordingSharedRingProducer {
    guard capacity >= 4_096 else { throw RecordingSharedRingError.invalidCapacity(capacity) }
    let storage = try RecordingSharedRingStorage.create(
      capacity: capacity,
      protocolVersion: protocolVersion
    )
    let exportedFD = dup(storage.fileDescriptor)
    guard exportedFD >= 0 else {
      throw RecordingSharedRingError.cannotCreateBackingFile(errno)
    }
    let descriptor = RecordingSharedRingDescriptor(
      fileHandle: FileHandle(fileDescriptor: exportedFD, closeOnDealloc: true),
      capacity: capacity,
      protocolVersion: protocolVersion
    )
    return RecordingSharedRingProducer(storage: storage, descriptor: descriptor)
  }

  private init(
    storage: RecordingSharedRingStorage,
    descriptor: RecordingSharedRingDescriptor
  ) {
    self.storage = storage
    self.descriptor = descriptor
  }

  @discardableResult
  public func write(_ payload: Data) -> Bool {
    let recordLength = MemoryLayout<UInt32>.size + payload.count
    guard payload.count <= Int(UInt32.max), recordLength < storage.capacity else { return false }
    let writePosition = ldtx_recording_ring_load_write(storage.header)
    let readPosition = ldtx_recording_ring_load_read(storage.header)
    guard writePosition >= readPosition else { return false }
    let used = writePosition - readPosition
    guard used <= UInt64(storage.capacity), UInt64(recordLength) <= UInt64(storage.capacity) - used
    else { return false }

    var length = UInt32(payload.count).littleEndian
    withUnsafeBytes(of: &length) { storage.copyIn($0, at: writePosition) }
    payload.withUnsafeBytes {
      storage.copyIn($0, at: writePosition + UInt64(MemoryLayout<UInt32>.size))
    }
    ldtx_recording_ring_store_write(storage.header, writePosition + UInt64(recordLength))
    return true
  }
}

public final class RecordingSharedRingConsumer: @unchecked Sendable {
  private let storage: RecordingSharedRingStorage

  public init(descriptor: RecordingSharedRingDescriptor) throws {
    storage = try RecordingSharedRingStorage.map(descriptor: descriptor)
  }

  public func read() -> Data? {
    let readPosition = ldtx_recording_ring_load_read(storage.header)
    let writePosition = ldtx_recording_ring_load_write(storage.header)
    guard writePosition >= readPosition else { return nil }
    let available = writePosition - readPosition
    guard available >= UInt64(MemoryLayout<UInt32>.size) else { return nil }

    var encodedLength = UInt32.zero
    withUnsafeMutableBytes(of: &encodedLength) {
      storage.copyOut(at: readPosition, into: $0)
    }
    let payloadLength = Int(UInt32(littleEndian: encodedLength))
    let recordLength = MemoryLayout<UInt32>.size + payloadLength
    guard payloadLength < storage.capacity, available >= UInt64(recordLength) else { return nil }

    var payload = Data(count: payloadLength)
    payload.withUnsafeMutableBytes {
      storage.copyOut(
        at: readPosition + UInt64(MemoryLayout<UInt32>.size),
        into: $0
      )
    }
    ldtx_recording_ring_store_read(storage.header, readPosition + UInt64(recordLength))
    return payload
  }
}

private final class RecordingSharedRingStorage: @unchecked Sendable {
  static let headerSize = MemoryLayout<LDTXRecordingSharedRingHeader>.stride

  let fileDescriptor: Int32
  let mapping: UnsafeMutableRawPointer
  let capacity: Int
  let mappedLength: Int

  var header: UnsafeMutablePointer<LDTXRecordingSharedRingHeader> {
    mapping.assumingMemoryBound(to: LDTXRecordingSharedRingHeader.self)
  }

  private var bytes: UnsafeMutableRawPointer { mapping.advanced(by: Self.headerSize) }

  static func create(capacity: Int, protocolVersion: UInt64) throws -> RecordingSharedRingStorage {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ldtx-recording-ring-\(UUID().uuidString)")
    let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw RecordingSharedRingError.cannotCreateBackingFile(errno) }
    unlink(url.path)
    let length = headerSize + capacity
    guard ftruncate(fd, off_t(length)) == 0 else {
      let error = errno
      close(fd)
      throw RecordingSharedRingError.cannotResizeBackingFile(error)
    }
    let storage = try map(fileDescriptor: fd, capacity: capacity, closesOnFailure: true)
    ldtx_recording_ring_initialize(storage.header, UInt64(capacity), protocolVersion)
    return storage
  }

  static func map(descriptor: RecordingSharedRingDescriptor) throws -> RecordingSharedRingStorage {
    guard descriptor.protocolVersion == RecordingSharedRingProducer.protocolVersion,
      descriptor.capacity >= 4_096
    else { throw RecordingSharedRingError.incompatibleDescriptor }
    let fd = dup(descriptor.fileHandle.fileDescriptor)
    guard fd >= 0 else { throw RecordingSharedRingError.cannotCreateBackingFile(errno) }
    let storage = try map(fileDescriptor: fd, capacity: descriptor.capacity, closesOnFailure: true)
    guard storage.header.pointee.capacity == UInt64(descriptor.capacity),
      storage.header.pointee.protocol_version == descriptor.protocolVersion
    else {
      throw RecordingSharedRingError.incompatibleDescriptor
    }
    return storage
  }

  private static func map(
    fileDescriptor: Int32,
    capacity: Int,
    closesOnFailure: Bool
  ) throws -> RecordingSharedRingStorage {
    let length = headerSize + capacity
    let mapping = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, fileDescriptor, 0)
    guard mapping != MAP_FAILED, let mapping else {
      let error = errno
      if closesOnFailure { close(fileDescriptor) }
      throw RecordingSharedRingError.cannotMapBackingFile(error)
    }
    return RecordingSharedRingStorage(
      fileDescriptor: fileDescriptor,
      mapping: mapping,
      capacity: capacity,
      mappedLength: length
    )
  }

  private init(
    fileDescriptor: Int32,
    mapping: UnsafeMutableRawPointer,
    capacity: Int,
    mappedLength: Int
  ) {
    self.fileDescriptor = fileDescriptor
    self.mapping = mapping
    self.capacity = capacity
    self.mappedLength = mappedLength
  }

  deinit {
    munmap(mapping, mappedLength)
    close(fileDescriptor)
  }

  func copyIn(_ source: UnsafeRawBufferPointer, at absolutePosition: UInt64) {
    copy(source: source, ringOffset: Int(absolutePosition % UInt64(capacity)))
  }

  func copyOut(at absolutePosition: UInt64, into destination: UnsafeMutableRawBufferPointer) {
    let offset = Int(absolutePosition % UInt64(capacity))
    let firstCount = min(destination.count, capacity - offset)
    if firstCount > 0 {
      destination.baseAddress?.copyMemory(from: bytes.advanced(by: offset), byteCount: firstCount)
    }
    let remaining = destination.count - firstCount
    if remaining > 0 {
      destination.baseAddress?.advanced(by: firstCount).copyMemory(from: bytes, byteCount: remaining)
    }
  }

  private func copy(source: UnsafeRawBufferPointer, ringOffset: Int) {
    let firstCount = min(source.count, capacity - ringOffset)
    if firstCount > 0 {
      bytes.advanced(by: ringOffset).copyMemory(from: source.baseAddress!, byteCount: firstCount)
    }
    let remaining = source.count - firstCount
    if remaining > 0 {
      bytes.copyMemory(from: source.baseAddress!.advanced(by: firstCount), byteCount: remaining)
    }
  }
}
