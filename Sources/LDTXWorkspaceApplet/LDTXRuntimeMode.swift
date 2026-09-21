// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum LDTXRuntimeMode {
  public static var recordingPreviewFixtureName: String? {
    #if DEBUG
      ProcessInfo.processInfo.environment["LDTX_RECORDING_PREVIEW_FIXTURE"]
    #else
      nil
    #endif
  }

  public static var isUITesting: Bool {
    #if DEBUG
      UserDefaults.standard.bool(forKey: "tokyo.kaito.ldtx.LDTX.isUITesting")
    #else
      false
    #endif
  }

  public static var discardsUnsavedChangesOnClose: Bool {
    #if DEBUG
      UserDefaults.standard.bool(forKey: "tokyo.kaito.ldtx.LDTX.discardsUnsavedChangesOnClose")
    #else
      false
    #endif
  }

  public static var isUnitTesting: Bool {
    // Xcode's CI configuration can build package dependencies without DEBUG.
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  public static var diagnosticsAreEnabled: Bool {
    !isUnitTesting && !isUITesting
  }

  public static func makeProgramLibraryUserDefaults() -> UserDefaults {
    #if DEBUG
      if isUITesting {
        let suiteName = "tokyo.kaito.ldtx.LDTX.UITests"
        let userDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
      }
    #endif

    return .standard
  }
}
