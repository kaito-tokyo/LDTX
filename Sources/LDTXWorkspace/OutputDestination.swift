// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftProtobuf

public struct OutputDestination: Codable, Equatable, Sendable {
    public var recordsLocally: Bool
    public var streamsToYouTube: Bool
    public var overridesOutputFolder: Bool
    public var outputFolderPath: String?

    public init(
        recordsLocally: Bool = true,
        streamsToYouTube: Bool = false,
        overridesOutputFolder: Bool = false,
        outputFolderPath: String? = nil
    ) {
        self.recordsLocally = recordsLocally
        self.streamsToYouTube = streamsToYouTube
        self.overridesOutputFolder = overridesOutputFolder
        self.outputFolderPath = outputFolderPath
    }

    /// Returns a normalized, self-consistent value. Any inconsistency resets
    /// the whole destination so partial old settings cannot change intent.
    public func normalized(fileManager: FileManager = .default) -> OutputDestination? {
        guard overridesOutputFolder else {
            return outputFolderPath == nil ? self : nil
        }
        guard let outputFolderPath, !outputFolderPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: outputFolderPath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fileManager.isWritableFile(atPath: url.path) else { return nil }
        var result = self
        result.outputFolderPath = url.path
        return result
    }

    public static let `default` = OutputDestination()
}

public struct ApplicationOutputPreferences: Codable, Equatable, Sendable {
    public var defaultOutputFolderPath: String?

    public init(defaultOutputFolderPath: String? = nil) {
        self.defaultOutputFolderPath = defaultOutputFolderPath
    }
}

public enum ApplicationOutputPreferencesPersistenceCodec {
    public static func encode(_ preferences: ApplicationOutputPreferences) throws -> Data {
        try preferences.protoMessage.serializedData()
    }

    public static func decode(from data: Data) throws -> ApplicationOutputPreferences {
        try Ldtx_App_V1_ApplicationOutputPreferences(serializedBytes: data).domainModel
    }
}

extension OutputDestination {
    var protoMessage: Ldtx_Workspace_V1_OutputDestination {
        var proto = Ldtx_Workspace_V1_OutputDestination()
        proto.recordsLocally = recordsLocally
        proto.streamsToYoutube = streamsToYouTube
        proto.overridesOutputFolder = overridesOutputFolder
        if let outputFolderPath { proto.outputFolderPath = outputFolderPath }
        return proto
    }
}

extension Ldtx_Workspace_V1_OutputDestination {
    var domainModel: OutputDestination {
        OutputDestination(
            recordsLocally: recordsLocally,
            streamsToYouTube: streamsToYoutube,
            overridesOutputFolder: overridesOutputFolder,
            outputFolderPath: hasOutputFolderPath ? outputFolderPath : nil
        )
    }
}

private extension ApplicationOutputPreferences {
    var protoMessage: Ldtx_App_V1_ApplicationOutputPreferences {
        var proto = Ldtx_App_V1_ApplicationOutputPreferences()
        if let defaultOutputFolderPath { proto.defaultOutputFolderPath = defaultOutputFolderPath }
        return proto
    }
}

private extension Ldtx_App_V1_ApplicationOutputPreferences {
    var domainModel: ApplicationOutputPreferences {
        ApplicationOutputPreferences(
            defaultOutputFolderPath: hasDefaultOutputFolderPath ? defaultOutputFolderPath : nil
        )
    }
}
