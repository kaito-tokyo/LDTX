// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspaceAppletModel

/// Persists application-wide, non-secret Settings in UserDefaults.
public struct ApplicationSettingsStore: @unchecked Sendable {
  public static let applicationOutputPreferencesKey =
    "tokyo.kaito.ldtx.application-output-preferences.v2"

  private let userDefaults: UserDefaults

  public init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
  }

  public func loadApplicationOutputPreferences() -> ApplicationOutputPreferences {
    guard let data = userDefaults.data(forKey: Self.applicationOutputPreferencesKey),
      !data.isEmpty,
      let preferences = try? ApplicationOutputPreferencesPersistenceCodec.decode(from: data)
    else { return ApplicationOutputPreferences() }
    return preferences
  }

  public func saveApplicationOutputPreferences(_ preferences: ApplicationOutputPreferences) {
    guard let data = try? ApplicationOutputPreferencesPersistenceCodec.encode(preferences) else {
      return
    }
    userDefaults.set(data, forKey: Self.applicationOutputPreferencesKey)
  }
}

public enum ApplicationOutputPreferencesPersistenceCodec {
  public static func encode(_ preferences: ApplicationOutputPreferences) throws -> Data {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    return try encoder.encode(preferences)
  }

  public static func decode(from data: Data) throws -> ApplicationOutputPreferences {
    try PropertyListDecoder().decode(ApplicationOutputPreferences.self, from: data)
  }
}
