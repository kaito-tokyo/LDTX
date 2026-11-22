// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCorelibs
import Security

struct YouTubeAuthorizationState: Codable, Equatable, Sendable {
  var accessToken: String
  var refreshToken: String?
  var expirationDate: Date
}

public enum YouTubeAuthorizationStoreError: Error, Equatable, LocalizedError {
  case encodingFailed
  case decodingFailed
  case keychainFailure(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .encodingFailed:
      "The YouTube authorization state could not be encoded for storage."
    case .decodingFailed:
      "The stored YouTube authorization state could not be decoded."
    case .keychainFailure(let status):
      "The Keychain operation failed with status \(status)."
    }
  }
}

public struct YouTubeAuthorizationStore {
  public static let defaultService = "tokyo.kaito.ldtx.youtube-auth"

  private let service: String
  private let keychainOperations: DataProtectionKeychainItem.Operations
  #if !LDTX_DISTRIBUTION
    private var file: YouTubeAuthFile?

    init(file: YouTubeAuthFile) {
      self.init()
      self.file = file
    }
  #endif

  public init(service: String = Self.defaultService) {
    self.init(service: service, keychainOperations: .system)
  }

  init(service: String, keychainOperations: DataProtectionKeychainItem.Operations) {
    self.service = service
    self.keychainOperations = keychainOperations
  }

  func load(clientID: String) throws -> YouTubeAuthorizationState? {
    #if !LDTX_DISTRIBUTION
      if let file {
        guard let data = try file.read().authorizations[clientID] else { return nil }
        return try decode(data)
      }
    #endif
    guard let keychainData = try loadFromKeychain(clientID: clientID) else {
      return nil
    }
    return try decode(keychainData)
  }

  func save(_ authState: YouTubeAuthorizationState, clientID: String) throws {
    let data = try encode(authState)
    #if !LDTX_DISTRIBUTION
      if let file {
        try file.update { $0.authorizations[clientID] = data }
        return
      }
    #endif
    try saveToKeychain(data, clientID: clientID)
  }

  public func delete(clientID: String) throws {
    #if !LDTX_DISTRIBUTION
      if let file {
        try file.update { $0.authorizations.removeValue(forKey: clientID) }
        return
      }
    #endif
    try deleteFromKeychain(clientID: clientID)
  }

  private func encode(_ authState: YouTubeAuthorizationState) throws -> Data {
    do {
      return try JSONEncoder().encode(authState)
    } catch {
      throw YouTubeAuthorizationStoreError.encodingFailed
    }
  }

  private func decode(_ data: Data) throws -> YouTubeAuthorizationState? {
    do {
      return try JSONDecoder().decode(YouTubeAuthorizationState.self, from: data)
    } catch let error as YouTubeAuthorizationStoreError {
      throw error
    } catch {
      // AppAuth stored secure keyed archives. They cannot be resumed by the
      // first-party token store, so report them as unauthenticated and allow
      // the user to authorize again.
      if data.starts(with: Data("bplist00".utf8)) { return nil }
      throw YouTubeAuthorizationStoreError.decodingFailed
    }
  }

  private func loadFromKeychain(clientID: String) throws -> Data? {
    try withKeychainFailure { try keychainItem(clientID: clientID).load() }
  }

  private func saveToKeychain(_ data: Data, clientID: String) throws {
    try withKeychainFailure { try keychainItem(clientID: clientID).save(data) }
  }

  private func deleteFromKeychain(clientID: String) throws {
    try withKeychainFailure { try keychainItem(clientID: clientID).delete() }
  }

  private func keychainItem(clientID: String) -> DataProtectionKeychainItem {
    DataProtectionKeychainItem(service: service, account: clientID, operations: keychainOperations)
  }

  private func withKeychainFailure<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as DataProtectionKeychainItem.StatusError {
      throw YouTubeAuthorizationStoreError.keychainFailure(error.status)
    }
  }
}
