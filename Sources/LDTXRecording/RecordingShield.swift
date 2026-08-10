// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Darwin
import Foundation

public enum RecordingShieldProfile {
  public static let statementType = "https://in-toto.io/Statement/v1"
  public static let predicateType = "https://ldtx.dev/attestation/recording-shield/v1"
  public static let profileVersion = "1.0"
  public static let packageRoot = "."
  public static let digestAlgorithm = "sha256"
  public static let pathPolicy = "utf8-nfc-relative-slash-v1"
  public static let entryPolicy = "regular-files-no-follow-v1"
  public static let verificationPolicy = "closed-world-v1"
  public static let manifestFileName = ".shield.json"
  public static let dsseFileName = ".shield.dsse.json"
  public static let checksumFileName = "SHA256SUM"
  public static let maximumManifestSize = 16 * 1024 * 1024
  public static let maximumJSONNestingDepth = 100
  public static let maximumPackageDirectoryDepth = 32
  static let rootExclusions = Set([manifestFileName, dsseFileName, checksumFileName])
}

public struct RecordingShieldStatement: Codable, Equatable, Sendable {
  public var type: String
  public var subject: [Subject]
  public var predicateType: String
  public var predicate: Predicate
  enum CodingKeys: String, CodingKey {
    case type = "_type"
    case subject, predicateType, predicate
  }

  public init(subject: [Subject]) {
    type = RecordingShieldProfile.statementType
    self.subject = subject
    predicateType = RecordingShieldProfile.predicateType
    predicate = Predicate()
  }
  public struct Subject: Codable, Equatable, Sendable {
    public var name: String
    public var digest: Digest
    public init(name: String, sha256: String) {
      self.name = name
      digest = Digest(sha256: sha256)
    }
  }
  public struct Digest: Codable, Equatable, Sendable {
    public var sha256: String
    public init(sha256: String) { self.sha256 = sha256 }
  }
  public struct Predicate: Codable, Equatable, Sendable {
    public var profileVersion = RecordingShieldProfile.profileVersion
    public var packageRoot = RecordingShieldProfile.packageRoot
    public var digestAlgorithm = RecordingShieldProfile.digestAlgorithm
    public var pathPolicy = RecordingShieldProfile.pathPolicy
    public var entryPolicy = RecordingShieldProfile.entryPolicy
    public var verificationPolicy = RecordingShieldProfile.verificationPolicy
    public init() {}
  }
}

public enum RecordingShieldCodec {
  public static func encode(_ value: RecordingShieldStatement) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0a)
    return data
  }
  public static func decode(_ data: Data) throws -> RecordingShieldStatement {
    guard String(data: data, encoding: .utf8) != nil else {
      throw CocoaError(.fileReadCorruptFile)
    }
    try RecordingShieldJSON.validateUniqueKeys(data)
    return try JSONDecoder().decode(RecordingShieldStatement.self, from: data)
  }
}

private enum RecordingShieldJSON {
  static func validateUniqueKeys(_ data: Data) throws {
    var parser = Parser(bytes: Array(data))
    try parser.value()
    parser.space()
    guard parser.index == parser.bytes.count else { throw CocoaError(.fileReadCorruptFile) }
  }
  private struct Parser {
    let bytes: [UInt8]
    var index = 0
    var depth = 0
    mutating func space() {
      while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
    mutating func value() throws {
      space()
      guard index < bytes.count else { throw CocoaError(.fileReadCorruptFile) }
      switch bytes[index] {
      case 123: try object()
      case 91: try array()
      case 34: _ = try string()
      case 116: try word("true")
      case 102: try word("false")
      case 110: try word("null")
      default: try number()
      }
    }
    mutating func object() throws {
      try enterContainer()
      defer { depth -= 1 }
      index += 1
      space()
      var keys = Set<String>()
      if take(125) { return }
      while true {
        space()
        let key = try string()
        guard keys.insert(key).inserted else { throw CocoaError(.fileReadCorruptFile) }
        space()
        guard take(58) else { throw CocoaError(.fileReadCorruptFile) }
        try value()
        space()
        if take(125) { return }
        guard take(44) else { throw CocoaError(.fileReadCorruptFile) }
      }
    }
    mutating func array() throws {
      try enterContainer()
      defer { depth -= 1 }
      index += 1
      space()
      if take(93) { return }
      while true {
        try value()
        space()
        if take(93) { return }
        guard take(44) else { throw CocoaError(.fileReadCorruptFile) }
      }
    }
    mutating func enterContainer() throws {
      guard depth < RecordingShieldProfile.maximumJSONNestingDepth else {
        throw CocoaError(.fileReadCorruptFile)
      }
      depth += 1
    }
    mutating func string() throws -> String {
      guard take(34) else { throw CocoaError(.fileReadCorruptFile) }
      var result = ""
      var raw = Data()
      func flushRaw() throws -> String {
        guard let string = String(data: raw, encoding: .utf8) else {
          throw CocoaError(.fileReadCorruptFile)
        }
        return string
      }
      while index < bytes.count {
        let byte = bytes[index]
        index += 1
        if byte == 34 {
          result += try flushRaw()
          return result
        }
        guard byte >= 0x20 else { throw CocoaError(.fileReadCorruptFile) }
        guard byte == 92 else {
          raw.append(byte)
          continue
        }
        result += try flushRaw()
        raw.removeAll(keepingCapacity: true)
        guard index < bytes.count else { throw CocoaError(.fileReadCorruptFile) }
        let escaped = bytes[index]
        index += 1
        switch escaped {
        case 34: result.append("\"")
        case 92: result.append("\\")
        case 47: result.append("/")
        case 98: result.append("\u{08}")
        case 102: result.append("\u{0C}")
        case 110: result.append("\n")
        case 114: result.append("\r")
        case 116: result.append("\t")
        case 117:
          let first = try unicodeEscape()
          if (0xD800...0xDBFF).contains(first) {
            guard index + 1 < bytes.count, bytes[index] == 92, bytes[index + 1] == 117 else {
              throw CocoaError(.fileReadCorruptFile)
            }
            index += 2
            let second = try unicodeEscape()
            guard (0xDC00...0xDFFF).contains(second),
              let scalar = UnicodeScalar(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00))
            else { throw CocoaError(.fileReadCorruptFile) }
            result.unicodeScalars.append(scalar)
          } else {
            guard !(0xDC00...0xDFFF).contains(first), let scalar = UnicodeScalar(first) else {
              throw CocoaError(.fileReadCorruptFile)
            }
            result.unicodeScalars.append(scalar)
          }
        default: throw CocoaError(.fileReadCorruptFile)
        }
      }
      throw CocoaError(.fileReadCorruptFile)
    }
    mutating func unicodeEscape() throws -> UInt32 {
      guard index + 4 <= bytes.count else { throw CocoaError(.fileReadCorruptFile) }
      var value: UInt32 = 0
      for byte in bytes[index..<(index + 4)] {
        let digit: UInt32
        switch byte {
        case 48...57: digit = UInt32(byte - 48)
        case 65...70: digit = UInt32(byte - 65 + 10)
        case 97...102: digit = UInt32(byte - 97 + 10)
        default: throw CocoaError(.fileReadCorruptFile)
        }
        value = value << 4 | digit
      }
      index += 4
      return value
    }
    mutating func word(_ string: String) throws {
      guard bytes.dropFirst(index).starts(with: string.utf8) else {
        throw CocoaError(.fileReadCorruptFile)
      }
      index += string.utf8.count
    }
    mutating func number() throws {
      let start = index
      while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) {
        index += 1
      }
      guard index > start else { throw CocoaError(.fileReadCorruptFile) }
    }
    mutating func take(_ byte: UInt8) -> Bool {
      if index < bytes.count && bytes[index] == byte {
        index += 1
        return true
      }
      return false
    }
  }
}

enum RecordingShieldHash {
  static func sha256(fileDescriptor descriptor: Int32) throws -> String {
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
