// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum OutputSettingsStorageKey {
    private static let prefix = "tokyo.kaito.ldtx.LDTX.ContentSettingsForm"

    static let broadcastSourceMode = "\(prefix).broadcastSourceMode"
    static let resolution = "\(prefix).resolution"
    static let frameRate = "\(prefix).frameRate"
    static let privacyStatus = "\(prefix).privacyStatus"
    static let latencyPreference = "\(prefix).latencyPreference"
    static let existingBroadcastID = "\(prefix).existingBroadcastID"
    static let captureOutputMode = "\(prefix).captureOutputMode"
    static let streamTitle = "\(prefix).streamTitle"
    static let streamDescription = "\(prefix).streamDescription"
    static let usesTemporaryStream = "\(prefix).usesTemporaryStream"
    static let localOutputBaseDirectoryPath = "\(prefix).localOutputBaseDirectoryPath"
}
