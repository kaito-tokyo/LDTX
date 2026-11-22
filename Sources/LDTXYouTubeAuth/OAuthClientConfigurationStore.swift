// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

public enum OAuthClientConfigurationStoreError: Error, Equatable, LocalizedError {
  case decodingFailed
  case keychainFailure(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .decodingFailed:
      "The stored OAuth client JSON could not be decoded."
    case .keychainFailure(let status):
      "The Keychain operation failed with status \(status)."
    }
  }
}

public struct OAuthClientConfigurationStore {
  public static let defaultService = "tokyo.kaito.ldtx.oauth-client"
  public static let defaultAccount = "google-oauth-client-json"

  private let keychainItem: YouTubeKeychainItem
  #if !LDTX_DISTRIBUTION
    private var file: YouTubeAuthFile?

    init(file: YouTubeAuthFile) {
      self.init()
      self.file = file
    }
  #endif

  public init(
    service: String = Self.defaultService,
    account: String = Self.defaultAccount
  ) {
    self.init(service: service, account: account, keychainOperations: .system)
  }

  init(service: String, account: String, keychainOperations: YouTubeKeychainItem.Operations) {
    keychainItem = YouTubeKeychainItem(
      service: service, account: account, operations: keychainOperations)
  }

  public func load() throws -> GoogleOAuthClientConfiguration? {
    #if !LDTX_DISTRIBUTION
      if let file {
        guard let data = try file.read().oauthClientJSON else { return nil }
        return try decode(data)
      }
    #endif
    guard let keychainData = try loadFromKeychain() else {
      return nil
    }
    return try decode(keychainData)
  }

  public func save(_ data: Data) throws {
    _ = try decode(data)
    #if !LDTX_DISTRIBUTION
      if let file {
        try file.update { $0.oauthClientJSON = data }
        return
      }
    #endif
    try saveToKeychain(data)
  }

  public func delete() throws {
    #if !LDTX_DISTRIBUTION
      if let file {
        try file.update { $0.oauthClientJSON = nil }
        return
      }
    #endif
    try deleteFromKeychain()
  }

  private func decode(_ data: Data) throws -> GoogleOAuthClientConfiguration {
    do {
      return try GoogleOAuthClientConfiguration(data: data)
    } catch {
      throw OAuthClientConfigurationStoreError.decodingFailed
    }
  }

  private func loadFromKeychain() throws -> Data? {
    try withKeychainFailure { try keychainItem.load() }
  }

  private func saveToKeychain(_ data: Data) throws {
    try withKeychainFailure { try keychainItem.save(data) }
  }

  private func deleteFromKeychain() throws {
    try withKeychainFailure { try keychainItem.delete() }
  }

  private func withKeychainFailure<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as YouTubeKeychainItem.StatusError {
      throw OAuthClientConfigurationStoreError.keychainFailure(error.status)
    }
  }
}
