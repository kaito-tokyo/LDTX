// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXRecordPlayerUI

public enum LDTXRuntimeMode {
  static var recordingPreviewFixture: RecordingPreviewScenarioFixture? {
    #if DEBUG
      ProcessInfo.processInfo.environment["LDTX_RECORDING_PREVIEW_FIXTURE"]
        .flatMap(RecordingPreviewScenarioFixture.init(rawValue:))
    #else
      nil
    #endif
  }

  public static var isPreview: Bool {
    #if DEBUG
      let environment = ProcessInfo.processInfo.environment
      return environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        || environment["XCODE_RUNNING_FOR_PLAYGROUNDS"] == "1"
    #else
      false
    #endif
  }

  static var isUITesting: Bool {
    #if DEBUG
      UserDefaults.standard.bool(forKey: "tokyo.kaito.ldtx.LDTX.isUITesting")
    #else
      false
    #endif
  }

  static var isUnitTesting: Bool {
    #if DEBUG
      ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    #else
      false
    #endif
  }

  static var diagnosticsAreEnabled: Bool {
    shouldEnableDiagnostics(
      unitTesting: isUnitTesting,
      uiTesting: isUITesting,
      preview: isPreview
    )
  }

  static func shouldEnableDiagnostics(
    unitTesting: Bool,
    uiTesting: Bool,
    preview: Bool
  ) -> Bool {
    !unitTesting && !uiTesting && !preview
  }

  static func makeProgramLibraryUserDefaults() -> UserDefaults {
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
