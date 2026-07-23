// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftProtobuf

/// Output destination settings shared by every Workspace opened in this app.
///
/// This is intentionally separate from `WorkspacePreferences`: output targets
/// are application-local, while a Workspace persists only its render contract.
public struct AppOutputSettings: Equatable, Sendable {
    public var recording: Recording
    public var youtube: YouTube

    public init(
        recording: Recording = .init(),
        youtube: YouTube = .init()
    ) {
        self.recording = recording
        self.youtube = youtube
    }

    public struct Recording: Equatable, Sendable {
        public var isEnabled: Bool
        public var baseDirectoryURL: URL?

        public init(isEnabled: Bool = false, baseDirectoryURL: URL? = nil) {
            self.isEnabled = isEnabled
            self.baseDirectoryURL = baseDirectoryURL
        }
    }

    public struct YouTube: Equatable, Sendable {
        public var isEnabled: Bool
        public var existingBroadcastID: String?
        public var streamTitle: String
        public var streamDescription: String

        public init(
            isEnabled: Bool = true,
            existingBroadcastID: String? = nil,
            streamTitle: String = "LDTX",
            streamDescription: String = ""
        ) {
            self.isEnabled = isEnabled
            self.existingBroadcastID = existingBroadcastID
            self.streamTitle = streamTitle
            self.streamDescription = streamDescription
        }
    }
}

public enum AppOutputSettingsPersistenceCodec {
    public static func encode(_ settings: AppOutputSettings) throws -> Data {
        try settings.protoMessage.serializedData()
    }

    public static func decode(from data: Data) throws -> AppOutputSettings {
        try Ldtx_App_V1_OutputSettings(serializedBytes: data).domainModel
    }
}

public struct AppPreviewSettings: Equatable, Sendable {
    public var prefersColor: Bool

    public init(prefersColor: Bool = false) {
        self.prefersColor = prefersColor
    }
}

public enum AppPreviewSettingsPersistenceCodec {
    public static func encode(_ settings: AppPreviewSettings) throws -> Data {
        var proto = Ldtx_App_V1_PreviewSettings()
        proto.prefersColor = settings.prefersColor
        return try proto.serializedData()
    }

    public static func decode(from data: Data) throws -> AppPreviewSettings {
        let proto = try Ldtx_App_V1_PreviewSettings(serializedBytes: data)
        return AppPreviewSettings(prefersColor: proto.prefersColor)
    }
}

private extension AppOutputSettings {
    var protoMessage: Ldtx_App_V1_OutputSettings {
        var proto = Ldtx_App_V1_OutputSettings()
        var protoRecording = Ldtx_App_V1_Recording()
        protoRecording.isEnabled = recording.isEnabled
        if let baseDirectoryURL = recording.baseDirectoryURL {
            protoRecording.baseDirectoryPath = baseDirectoryURL.path
        }
        proto.recording = protoRecording

        var protoYouTube = Ldtx_App_V1_YouTube()
        protoYouTube.isEnabled = youtube.isEnabled
        if let existingBroadcastID = youtube.existingBroadcastID {
            protoYouTube.existingBroadcastID = existingBroadcastID
        }
        protoYouTube.streamTitle = youtube.streamTitle
        protoYouTube.streamDescription = youtube.streamDescription
        proto.youtube = protoYouTube
        return proto
    }
}

private extension Ldtx_App_V1_OutputSettings {
    var domainModel: AppOutputSettings {
        AppOutputSettings(
            recording: .init(
                isEnabled: recording.isEnabled,
                baseDirectoryURL: recording.hasBaseDirectoryPath
                    ? URL(fileURLWithPath: recording.baseDirectoryPath, isDirectory: true)
                    : nil
            ),
            youtube: .init(
                isEnabled: youtube.isEnabled,
                existingBroadcastID: youtube.hasExistingBroadcastID ? youtube.existingBroadcastID : nil,
                streamTitle: youtube.streamTitle.isEmpty ? "LDTX" : youtube.streamTitle,
                streamDescription: youtube.streamDescription
            )
        )
    }
}
