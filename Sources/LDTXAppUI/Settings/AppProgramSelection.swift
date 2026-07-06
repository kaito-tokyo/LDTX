// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

public enum BroadcastSourceMode: String, CaseIterable, Identifiable, Sendable {
    case createNew
    case useExisting

    public var id: String { rawValue }
}

public enum CaptureOutputMode: String, CaseIterable, Identifiable, Sendable {
    case youtube
    case record
    case youtubeAndRecord

    public var id: String { rawValue }

    public var streamsToYouTube: Bool {
        self == .youtube || self == .youtubeAndRecord
    }

    public var recordsLocally: Bool {
        self == .record || self == .youtubeAndRecord
    }
}
