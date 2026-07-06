// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

enum BroadcastSourceMode: String, CaseIterable, Identifiable {
    case createNew
    case useExisting

    var id: String { rawValue }
}

enum CaptureOutputMode: String, CaseIterable, Identifiable {
    case youtube
    case record
    case youtubeAndRecord

    var id: String { rawValue }

    var streamsToYouTube: Bool {
        self == .youtube || self == .youtubeAndRecord
    }

    var recordsLocally: Bool {
        self == .record || self == .youtubeAndRecord
    }
}
