// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
internal import LDTXNanopbGenerated
package import nanopb

public enum NanopbError: Error, Sendable {
  case malformed, wrongWireType, invalidUTF8, invalidJSON, recursionLimit
}

/// Shared entry points only. Field dispatch and model mapping are generated per type.
public protocol NanopbMessage: Hashable, Sendable {
  init()
  mutating func decode(from reader: inout NanopbReader) throws
  func encode(to writer: inout NanopbWriter) throws
  func encodeSubmessage(_ number: UInt32, to writer: inout NanopbWriter) throws
  var jsonObject: [String: Any] { get }
  mutating func merge(jsonObject: [String: Any]) throws
}

extension NanopbMessage {
  public static func with(_ body: (inout Self) throws -> Void) rethrows -> Self {
    var value = Self()
    try body(&value)
    return value
  }

  public init<Bytes: ContiguousBytes>(serializedBytes: Bytes) throws {
    self.init()
    try serializedBytes.withUnsafeBytes { bytes in
      var reader = NanopbReader(
        stream: pb_istream_from_buffer(
          bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count), depth: 0)
      try decode(from: &reader)
    }
  }

  public func serializedData() throws -> Data {
    var sizing = NanopbWriter.sizing()
    try encode(to: &sizing)
    var result = Data(count: sizing.count)
    try result.withUnsafeMutableBytes { bytes in
      var writer = NanopbWriter(
        stream: pb_ostream_from_buffer(
          bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count))
      try encode(to: &writer)
      guard writer.count == bytes.count else { throw NanopbError.malformed }
    }
    return result
  }

  public init(jsonUTF8Data: Data) throws {
    self.init()
    guard let object = try JSONSerialization.jsonObject(with: jsonUTF8Data) as? [String: Any] else {
      throw NanopbError.invalidJSON
    }
    try merge(jsonObject: object)
  }

  public func jsonUTF8Data() throws -> Data {
    try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
  }
}

public struct NanopbReader {
  fileprivate var stream: pb_istream_t
  fileprivate let depth: Int
  fileprivate init(stream: pb_istream_t, depth: Int) {
    self.stream = stream
    self.depth = depth
  }

  public var hasRemaining: Bool { stream.bytes_left > 0 }

  package mutating func decodeMessage<Value, CMessage>(
    into value: inout Value, descriptor: pb_msgdesc_t,
    make: (UnsafeMutableRawPointer) -> CMessage,
    field: @escaping (inout Value, UInt32, inout NanopbReader) throws -> Void
  ) throws {
    guard depth < 64 else { throw NanopbError.recursionLimit }
    let state = DecodeState(value: value, depth: depth + 1, field: field)
    var context = ldtx_nanopb_context(
      state: Unmanaged.passUnretained(state).toOpaque(), decode: decodeCallback, encode: nil)
    let success = withUnsafeMutablePointer(to: &context) { context in
      var message = make(UnsafeMutableRawPointer(context))
      return withUnsafePointer(to: descriptor) { descriptor in
        ldtx_nanopb_decode(&stream, descriptor, &message)
      }
    }
    if let error = state.error { throw error }
    guard success, stream.bytes_left == 0 else { throw NanopbError.malformed }
    value = state.value
  }

  public mutating func varint() throws -> UInt64 {
    var value: UInt64 = 0
    guard pb_decode_varint(&stream, &value) else { throw NanopbError.malformed }
    return value
  }

  public mutating func varint32() throws -> UInt32 {
    var value: UInt32 = 0
    guard pb_decode_varint32(&stream, &value) else { throw NanopbError.malformed }
    return value
  }

  public mutating func bool() throws -> Bool {
    var value = false
    guard pb_decode_bool(&stream, &value) else { throw NanopbError.malformed }
    return value
  }

  public mutating func svarint() throws -> Int64 {
    var value: Int64 = 0
    guard pb_decode_svarint(&stream, &value) else { throw NanopbError.malformed }
    return value
  }

  public mutating func fixed32() throws -> UInt32 {
    var value: UInt32 = 0
    guard pb_decode_fixed32(&stream, &value) else { throw NanopbError.malformed }
    return value
  }

  public mutating func fixed64() throws -> UInt64 {
    var value: UInt64 = 0
    guard pb_decode_fixed64(&stream, &value) else { throw NanopbError.malformed }
    return value
  }

  public mutating func message<T: NanopbMessage>(merging value: T = T()) throws -> T {
    var result = value
    try result.decode(from: &self)
    return result
  }

  public mutating func string() throws -> String {
    let count = stream.bytes_left
    return try String(unsafeUninitializedCapacity: count) { output in
      guard pb_read(&stream, output.baseAddress, count) else { throw NanopbError.malformed }
      guard validUTF8(UnsafeBufferPointer(start: output.baseAddress, count: count)) else {
        throw NanopbError.invalidUTF8
      }
      return count
    }
  }

  public mutating func bytes() throws -> Data {
    var result = Data(count: stream.bytes_left)
    try result.withUnsafeMutableBytes { output in
      guard pb_read(&stream, output.bindMemory(to: UInt8.self).baseAddress, output.count) else {
        throw NanopbError.malformed
      }
    }
    return result
  }
}

private func validUTF8(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
  // nanopb's optional pb_validate_utf8 takes a NUL-terminated C string.
  // Unicode.UTF8 validates the complete length-delimited field, including NUL.
  var input = bytes.makeIterator()
  var decoder = Unicode.UTF8()
  while true {
    switch decoder.decode(&input) {
    case .scalarValue: continue
    case .emptyInput: return true
    case .error: return false
    }
  }
}

public struct NanopbWriter {
  fileprivate var stream: pb_ostream_t
  fileprivate var count: Int { stream.bytes_written }

  fileprivate static func sizing() -> Self {
    // Swift equivalent of the PB_OSTREAM_SIZING aggregate initializer.
    Self(stream: pb_ostream_t())
  }

  private mutating func tag(_ number: UInt32, _ wire: pb_wire_type_t) throws {
    guard pb_encode_tag(&stream, wire, number) else { throw NanopbError.malformed }
  }

  public mutating func varint(_ number: UInt32, _ value: UInt64) throws {
    try tag(number, PB_WT_VARINT)
    guard pb_encode_varint(&stream, value) else { throw NanopbError.malformed }
  }

  public mutating func svarint(_ number: UInt32, _ value: Int64) throws {
    try tag(number, PB_WT_VARINT)
    guard pb_encode_svarint(&stream, value) else { throw NanopbError.malformed }
  }

  public mutating func fixed32(_ number: UInt32, _ value: UInt32) throws {
    try tag(number, PB_WT_32BIT)
    var value = value
    guard pb_encode_fixed32(&stream, &value) else { throw NanopbError.malformed }
  }

  public mutating func fixed64(_ number: UInt32, _ value: UInt64) throws {
    try tag(number, PB_WT_64BIT)
    var value = value
    guard pb_encode_fixed64(&stream, &value) else { throw NanopbError.malformed }
  }

  public mutating func string(_ number: UInt32, _ value: String) throws {
    var value = value
    try value.withUTF8 { try bytes(number, $0) }
  }

  public mutating func bytes<T: ContiguousBytes>(_ number: UInt32, _ value: T) throws {
    try tag(number, PB_WT_STRING)
    try value.withUnsafeBytes { buffer in
      guard pb_encode_string(&stream, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
      else {
        throw NanopbError.malformed
      }
    }
  }

  public mutating func message<T: NanopbMessage>(_ number: UInt32, _ value: T) throws {
    try value.encodeSubmessage(number, to: &self)
  }

  package mutating func encodeMessage<Value, CMessage>(
    _ value: Value, descriptor: pb_msgdesc_t,
    make: (UnsafeMutableRawPointer) -> CMessage, fieldNumber: UInt32?,
    field: @escaping (Value, UInt32, inout NanopbWriter) throws -> Void
  ) throws {
    let state = EncodeState(value: value, field: field)
    var context = ldtx_nanopb_context(
      state: Unmanaged.passUnretained(state).toOpaque(), decode: nil, encode: encodeCallback)
    if let fieldNumber { try tag(fieldNumber, PB_WT_STRING) }
    let success = withUnsafeMutablePointer(to: &context) { context in
      var message = make(UnsafeMutableRawPointer(context))
      return withUnsafePointer(to: descriptor) { descriptor in
        if fieldNumber != nil {
          return pb_encode_submessage(&stream, descriptor, &message)
        }
        return pb_encode(&stream, descriptor, &message)
      }
    }
    if let error = state.error { throw error }
    guard success else { throw NanopbError.malformed }
  }
}

// Contexts live only for a synchronous pb_decode/pb_encode call. C keeps
// pointers to them, never a copy of any String/Data/Array payload.
private class CallbackState {
  var error: (any Error)?
  func decode(_ field: UInt32, from reader: inout NanopbReader) throws {
    throw NanopbError.malformed
  }
  func encode(_ field: UInt32, to writer: inout NanopbWriter) throws {
    throw NanopbError.malformed
  }
  var depth: Int { 0 }
}

private final class DecodeState<Value>: CallbackState {
  var value: Value
  let level: Int
  let field: (inout Value, UInt32, inout NanopbReader) throws -> Void
  init(
    value: Value, depth: Int,
    field: @escaping (inout Value, UInt32, inout NanopbReader) throws -> Void
  ) {
    self.value = value
    level = depth
    self.field = field
  }
  override var depth: Int { level }
  override func decode(_ number: UInt32, from reader: inout NanopbReader) throws {
    try field(&value, number, &reader)
  }
}

private final class EncodeState<Value>: CallbackState {
  let value: Value
  let field: (Value, UInt32, inout NanopbWriter) throws -> Void
  init(value: Value, field: @escaping (Value, UInt32, inout NanopbWriter) throws -> Void) {
    self.value = value
    self.field = field
  }
  override func encode(_ number: UInt32, to writer: inout NanopbWriter) throws {
    try field(value, number, &writer)
  }
}

private func decodeCallback(
  _ stream: UnsafeMutablePointer<pb_istream_t>?, _ field: UInt32,
  _ opaque: UnsafeMutableRawPointer?
) -> Bool {
  guard let stream, let opaque else { return false }
  let state = Unmanaged<CallbackState>.fromOpaque(opaque).takeUnretainedValue()
  var reader = NanopbReader(stream: stream.pointee, depth: state.depth)
  defer { stream.pointee = reader.stream }
  do {
    try state.decode(field, from: &reader)
    return true
  } catch {
    state.error = error
    return false
  }
}

private func encodeCallback(
  _ stream: UnsafeMutablePointer<pb_ostream_t>?, _ field: UInt32,
  _ opaque: UnsafeMutableRawPointer?
) -> Bool {
  guard let stream, let opaque else { return false }
  let state = Unmanaged<CallbackState>.fromOpaque(opaque).takeUnretainedValue()
  var writer = NanopbWriter(stream: stream.pointee)
  defer { stream.pointee = writer.stream }
  do {
    try state.encode(field, to: &writer)
    return true
  } catch {
    state.error = error
    return false
  }
}
