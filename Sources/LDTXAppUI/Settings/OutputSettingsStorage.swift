// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum OutputSettingsStorageKey {
    private static let prefix = "tokyo.kaito.ldtx.LDTX.ContentSettingsForm"

    public static let resolution = "\(prefix).resolution"
    public static let frameRate = "\(prefix).frameRate"
    public static let existingBroadcastID = "\(prefix).existingBroadcastID"
    public static let captureOutputMode = "\(prefix).captureOutputMode"
    public static let streamTitle = "\(prefix).streamTitle"
    public static let streamDescription = "\(prefix).streamDescription"
    public static let usesTemporaryStream = "\(prefix).usesTemporaryStream"
    public static let localOutputBaseDirectoryPath = "\(prefix).localOutputBaseDirectoryPath"
    public static let prefersColorPreview = "\(prefix).prefersColorPreview"
}
