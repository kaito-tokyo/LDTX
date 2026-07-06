// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum LDTXRuntimeMode {
    static var isPreview: Bool {
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
