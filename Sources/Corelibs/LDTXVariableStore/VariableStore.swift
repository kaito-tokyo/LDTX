// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

public enum VariableItem: String, CaseIterable, Hashable, Sendable {
  case text, label, confidence

  public var emptyValue: String { self == .confidence ? "0" : "" }
}

public struct VariableKey: Hashable, Identifiable, Sendable {
  public let visionID: Int64
  public let item: VariableItem
  public var id: Self { self }
  public var path: String { "visions/\(visionID)/\(item.rawValue)" }

  public init(visionID: Int64, item: VariableItem) {
    self.visionID = visionID
    self.item = item
  }

  public init(path: String) throws {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "visions",
      let visionID = Int64(parts[1]), String(visionID) == parts[1],
      let item = VariableItem(rawValue: String(parts[2]))
    else { throw VariableStoreError.invalidPath(path) }
    self.init(visionID: visionID, item: item)
  }
}

public enum VariableStoreError: Error, Equatable, Sendable {
  case invalidPath(String)
  case unregisteredKey(VariableKey)
}

/// A reader can apply item-specific processing without changing the stored representation.
public protocol VariableReader: Sendable {
  func read(_ value: String, for key: VariableKey) throws -> String
}

public struct StoredVariableReader: VariableReader {
  public init() {}
  public func read(_ value: String, for key: VariableKey) -> String { value }
}

/// A fixed inventory of ephemeral string values.
public struct VariableStore: Sendable {
  public let keys: Set<VariableKey>
  private var values: [VariableKey: String]
  private var readers: [VariableKey: any VariableReader] = [:]

  public init(keys: Set<VariableKey>) {
    self.keys = keys
    values = Dictionary(uniqueKeysWithValues: keys.map { ($0, $0.item.emptyValue) })
  }

  public func read(_ key: VariableKey) throws -> String {
    guard let value = values[key] else { throw VariableStoreError.unregisteredKey(key) }
    return try (readers[key] ?? StoredVariableReader()).read(value, for: key)
  }

  /// Validates the complete update before changing any value.
  public mutating func update(_ updates: [VariableKey: String]) throws {
    for key in updates.keys where !keys.contains(key) {
      throw VariableStoreError.unregisteredKey(key)
    }
    values.merge(updates) { _, new in new }
  }

  public mutating func setReader(_ reader: any VariableReader, for key: VariableKey) throws {
    guard keys.contains(key) else { throw VariableStoreError.unregisteredKey(key) }
    readers[key] = reader
  }

  public mutating func reset(visionID: Int64) {
    for key in keys where key.visionID == visionID { values[key] = key.item.emptyValue }
  }
}
