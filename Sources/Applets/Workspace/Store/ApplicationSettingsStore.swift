// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspaceAppletModel

/// Persists application-wide, non-secret Settings in UserDefaults.
public struct ApplicationSettingsStore: @unchecked Sendable {
  public static let applicationOutputPreferencesKey =
    "tokyo.kaito.ldtx.application-output-preferences.v1"
  public static let legacyOutputSettingsKey = "tokyo.kaito.ldtx.output-settings.v1"

  private let userDefaults: UserDefaults

  public init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
  }

  public func loadApplicationOutputPreferences() -> ApplicationOutputPreferences {
    migrateLegacyOutputPreferencesIfNeeded()
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

  private func migrateLegacyOutputPreferencesIfNeeded() {
    guard userDefaults.data(forKey: Self.applicationOutputPreferencesKey)?.isEmpty != false,
      let legacyData = userDefaults.data(forKey: Self.legacyOutputSettingsKey),
      let migrated =
        try? ApplicationOutputPreferencesPersistenceCodec
        .migrateLegacyOutputSettingsIfNeeded(currentData: Data(), legacyData: legacyData)
    else { return }
    userDefaults.set(migrated, forKey: Self.applicationOutputPreferencesKey)
  }
}

public enum ApplicationOutputPreferencesPersistenceCodec {
  public static func encode(_ preferences: ApplicationOutputPreferences) throws -> Data {
    try preferences.protoMessage.serializedData()
  }

  public static func decode(from data: Data) throws -> ApplicationOutputPreferences {
    try Ldtx_App_V1_ApplicationOutputPreferences(serializedBytes: data).domainModel
  }

  public static func migrateLegacyOutputSettings(from data: Data) throws
    -> ApplicationOutputPreferences?
  {
    let legacy = try Ldtx_App_V1_LegacyOutputSettings(serializedBytes: data)
    guard legacy.hasRecording,
      legacy.recording.hasBaseDirectoryPath,
      legacy.recording.baseDirectoryPath.hasPrefix("/")
    else { return nil }
    let path = URL(
      fileURLWithPath: legacy.recording.baseDirectoryPath,
      isDirectory: true
    ).standardizedFileURL.path
    return ApplicationOutputPreferences(defaultOutputFolderPath: path)
  }

  public static func migrateLegacyOutputSettingsIfNeeded(
    currentData: Data,
    legacyData: Data
  ) throws -> Data? {
    guard currentData.isEmpty,
      !legacyData.isEmpty,
      let preferences = try migrateLegacyOutputSettings(from: legacyData)
    else { return nil }
    return try encode(preferences)
  }
}

extension ApplicationOutputPreferences {
  fileprivate var protoMessage: Ldtx_App_V1_ApplicationOutputPreferences {
    var proto = Ldtx_App_V1_ApplicationOutputPreferences()
    if let defaultOutputFolderPath { proto.defaultOutputFolderPath = defaultOutputFolderPath }
    return proto
  }
}

extension Ldtx_App_V1_ApplicationOutputPreferences {
  fileprivate var domainModel: ApplicationOutputPreferences {
    ApplicationOutputPreferences(
      defaultOutputFolderPath: hasDefaultOutputFolderPath ? defaultOutputFolderPath : nil
    )
  }
}
