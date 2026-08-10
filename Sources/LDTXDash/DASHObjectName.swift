// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct DASHObjectName: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init(rawValue: String) {
    precondition(Self.isValid(rawValue), "Invalid DASH object name")
    self.rawValue = rawValue
  }

  public init(validating rawValue: String) throws {
    guard Self.isValid(rawValue) else {
      throw DASHObjectNameError.invalidName(rawValue)
    }
    self.rawValue = rawValue
  }

  public var description: String { rawValue }

  public static let manifest = DASHObjectName(rawValue: "source.mpd")

  public static func mediaSegment(number: Int) throws -> DASHObjectName {
    guard number >= 0 else {
      throw DASHObjectNameError.invalidSegmentNumber(number)
    }
    return try DASHObjectName(validating: String(format: "media%09d.mp4", number))
  }

  public static func isValid(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 128 else { return false }
    guard !value.contains(".."), !value.contains("/") else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      switch scalar.value {
      case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
        return true
      case 0x2D, 0x2E, 0x5F:
        return true
      default:
        return false
      }
    }
  }
}

public enum DASHObjectNameError: Error, Equatable, LocalizedError {
  case invalidName(String)
  case invalidSegmentNumber(Int)

  public var errorDescription: String? {
    switch self {
    case .invalidName(let name):
      "Invalid DASH object name: \(name)"
    case .invalidSegmentNumber(let number):
      "Invalid DASH media segment number: \(number)"
    }
  }
}
