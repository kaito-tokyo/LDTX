// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

internal import nanopb

#if os(Linux)
  import FoundationEssentials
#else
  import Foundation
#endif

protocol NanopbConvertibleMessage: NanopbMessage {
  associatedtype CMessage
  static var emptyCMessage: CMessage { get }
  static var descriptor: pb_msgdesc_t { get }
  init(cMessage: CMessage) throws
  func write(to message: inout CMessage) throws
}

extension NanopbConvertibleMessage {
  func makeCMessage() throws -> CMessage {
    var message = Self.emptyCMessage
    do {
      try write(to: &message)
      return message
    } catch {
      NanopbCodec.release(&message, descriptor: Self.descriptor)
      throw error
    }
  }

  static func decode<Bytes: ContiguousBytes>(_ bytes: Bytes) throws -> Self {
    try NanopbCodec.decode(bytes, initial: emptyCMessage, descriptor: descriptor) {
      try Self(cMessage: $0)
    }
  }

  func encode() throws -> Data {
    try NanopbCodec.encode(makeCMessage(), descriptor: Self.descriptor)
  }
}

protocol NanopbMapEntry: NanopbConvertibleMessage {
  associatedtype Key: Hashable
  associatedtype Value
  var key: Key? { get set }
  var value: Value? { get set }
  static var defaultKey: Key { get }
  static var defaultValue: Value { get }
}

extension NanopbCodec {
  static func optionalString(_ bytes: UnsafeMutablePointer<pb_bytes_array_t>?) throws -> String? {
    try bytes.map { try string($0) }
  }

  static func optionalData(_ bytes: UnsafeMutablePointer<pb_bytes_array_t>?) throws -> Data? {
    try bytes.map { try data($0) }
  }

  static func decodeEnum<Value, CValue>(_ value: CValue, as type: Value.Type) throws -> Value
  where
    Value: RawRepresentable, Value.RawValue == Int,
    CValue: RawRepresentable, CValue.RawValue: FixedWidthInteger
  {
    guard let result = Value(rawValue: Int(Int32(truncatingIfNeeded: value.rawValue))) else {
      throw NanopbError.malformed
    }
    return result
  }

  static func encodeEnum<Value, CValue>(_ value: Value, as type: CValue.Type) throws -> CValue
  where
    Value: RawRepresentable, Value.RawValue == Int,
    CValue: RawRepresentable, CValue.RawValue: FixedWidthInteger
  {
    guard let raw = Int32(exactly: value.rawValue),
      let result = CValue(rawValue: .init(truncatingIfNeeded: raw))
    else { throw NanopbError.malformed }
    return result
  }

  static func array<Value, CValue>(
    _ storage: UnsafeMutablePointer<CValue>?, count: pb_size_t,
    decode: (CValue) throws -> Value
  ) throws -> [Value] {
    guard count == 0 || storage != nil else { throw NanopbError.malformed }
    return try UnsafeBufferPointer(start: storage, count: Int(count)).map(decode)
  }

  // The enclosing C message owns storage immediately. Count includes only fully
  // constructed elements; makeCMessage releases them if a later conversion fails.
  // Each throwing encode must release its own incomplete value before throwing.
  static func copyArray<Value, CValue>(
    _ values: [Value], to storage: inout UnsafeMutablePointer<CValue>?,
    count: inout pb_size_t, encode: (Value) throws -> CValue
  ) throws {
    guard !values.isEmpty else { return }
    _ = try Self.count(values.count)
    let buffer = try allocate(CValue.self, count: values.count)
    storage = buffer
    for value in values {
      buffer[Int(count)] = try encode(value)
      count += 1
    }
  }

  static func map<Entry: NanopbMapEntry>(
    _ storage: UnsafeMutablePointer<Entry.CMessage>?, count: pb_size_t, entry: Entry.Type
  ) throws -> [Entry.Key: Entry.Value] {
    var result: [Entry.Key: Entry.Value] = [:]
    for item in try array(storage, count: count, decode: Entry.init(cMessage:)) {
      result[item.key ?? Entry.defaultKey] = item.value ?? Entry.defaultValue
    }
    return result
  }

  static func copyMap<Entry: NanopbMapEntry>(
    _ values: [Entry.Key: Entry.Value], to storage: inout UnsafeMutablePointer<Entry.CMessage>?,
    count: inout pb_size_t, entry: Entry.Type, less: (Entry.Key, Entry.Key) -> Bool
  ) throws {
    let entries = values.keys.sorted(by: less).map { key in
      var entry = Entry()
      entry.key = key
      entry.value = values[key]
      return entry
    }
    try copyArray(entries, to: &storage, count: &count) { try $0.makeCMessage() }
  }
}

protocol NanopbEnumeration: RawRepresentable, Codable where RawValue == Int {}

extension NanopbEnumeration {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(Int32.self)
    guard let value = Self(rawValue: Int(raw)) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid enum value")
    }
    self = value
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    guard let value = Int32(exactly: rawValue) else {
      throw EncodingError.invalidValue(
        rawValue,
        .init(
          codingPath: encoder.codingPath,
          debugDescription: "Protobuf enum values must fit Int32"))
    }
    try container.encode(value)
  }
}
