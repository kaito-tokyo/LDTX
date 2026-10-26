// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

internal import LDTXNanopbGenerated
internal import nanopb

#if os(Linux)
  import FoundationEssentials
#else
  import Foundation
#endif

#if os(Linux)
  internal import Glibc
#else
  internal import Darwin
#endif

public enum NanopbError: Error, Sendable {
  case malformed, invalidUTF8, allocationFailure
}

public protocol NanopbMessage: Hashable, Sendable, Codable {
  init()
  init<Bytes: ContiguousBytes>(serializedBytes: Bytes) throws
  func serializedData() throws -> Data
}

extension NanopbMessage {
  public static func with(_ body: (inout Self) throws -> Void) rethrows -> Self {
    var value = Self()
    try body(&value)
    return value
  }

}

// C owns all intermediate allocations. Copy into Swift before releasing them.
enum NanopbCodec {
  static func decode<Bytes: ContiguousBytes, CMessage, Value>(
    _ bytes: Bytes, initial: CMessage, descriptor: pb_msgdesc_t,
    copy: (CMessage) throws -> Value
  ) throws -> Value {
    var message = initial
    defer { release(&message, descriptor: descriptor) }
    return try bytes.withUnsafeBytes { buffer in
      var stream = pb_istream_from_buffer(
        buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
      let success = withUnsafeMutablePointer(to: &message) { message in
        withUnsafePointer(to: descriptor) {
          pb_decode(&stream, $0, UnsafeMutableRawPointer(message))
        }
      }
      guard success, stream.bytes_left == 0 else { throw NanopbError.malformed }
      return try copy(message)
    }
  }

  static func encode<CMessage>(_ value: CMessage, descriptor: pb_msgdesc_t) throws -> Data {
    var message = value
    defer { release(&message, descriptor: descriptor) }
    return try withUnsafePointer(to: &message) { message in
      try withUnsafePointer(to: descriptor) { descriptor in
        var count = 0
        guard pb_get_encoded_size(&count, descriptor, UnsafeRawPointer(message)) else {
          throw NanopbError.malformed
        }
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { buffer in
          var stream = pb_ostream_from_buffer(
            buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
          guard pb_encode(&stream, descriptor, UnsafeRawPointer(message)),
            stream.bytes_written == buffer.count
          else {
            throw NanopbError.malformed
          }
        }
        return result
      }
    }
  }

  static func release<CMessage>(_ message: inout CMessage, descriptor: pb_msgdesc_t) {
    withUnsafeMutablePointer(to: &message) { message in
      withUnsafePointer(to: descriptor) { pb_release($0, UnsafeMutableRawPointer(message)) }
    }
  }

  static func count(_ count: Int) throws -> pb_size_t {
    guard let result = pb_size_t(exactly: count) else { throw NanopbError.allocationFailure }
    return result
  }

  // calloc/free matches the allocator used by the official nanopb package.
  static func allocate<Element>(_ type: Element.Type, count: Int) throws -> UnsafeMutablePointer<
    Element
  > {
    guard count > 0, let storage = calloc(count, MemoryLayout<Element>.stride) else {
      throw NanopbError.allocationFailure
    }
    return storage.bindMemory(to: Element.self, capacity: count)
  }

  static func makeBytes<Bytes: ContiguousBytes>(_ bytes: Bytes) throws -> UnsafeMutablePointer<
    pb_bytes_array_t
  > {
    try bytes.withUnsafeBytes { buffer in
      let size = try count(buffer.count)
      let (allocationSize, overflow) = MemoryLayout<pb_bytes_array_t>.size.addingReportingOverflow(
        buffer.count)
      guard !overflow, let storage = calloc(1, allocationSize) else {
        throw NanopbError.allocationFailure
      }
      let result = storage.bindMemory(to: pb_bytes_array_t.self, capacity: 1)
      result.pointee.size = size
      if let baseAddress = buffer.baseAddress, buffer.count > 0 {
        storage.advanced(by: MemoryLayout<pb_bytes_array_t>.offset(of: \.bytes)!)
          .copyMemory(from: baseAddress, byteCount: buffer.count)
      }
      return result
    }
  }

  private static func buffer(_ bytes: UnsafeMutablePointer<pb_bytes_array_t>)
    -> UnsafeRawBufferPointer
  {
    UnsafeRawBufferPointer(
      start: UnsafeRawPointer(bytes).advanced(
        by: MemoryLayout<pb_bytes_array_t>.offset(of: \.bytes)!),
      count: Int(bytes.pointee.size))
  }

  static func data(_ bytes: UnsafeMutablePointer<pb_bytes_array_t>?) throws -> Data {
    guard let bytes else { throw NanopbError.malformed }
    return Data(buffer(bytes))
  }

  static func string(_ bytes: UnsafeMutablePointer<pb_bytes_array_t>?) throws -> String {
    guard let bytes else { throw NanopbError.malformed }
    guard let result = String(bytes: buffer(bytes), encoding: .utf8) else {
      throw NanopbError.invalidUTF8
    }
    return result
  }

  static func makeString(_ value: String) throws -> UnsafeMutablePointer<pb_bytes_array_t> {
    var value = value
    return try value.withUTF8 { try makeBytes($0) }
  }
}
