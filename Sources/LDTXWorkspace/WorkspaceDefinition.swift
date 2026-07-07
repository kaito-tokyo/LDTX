// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram

public struct WorkspaceDefinition: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var programs: [SavedProgramDefinitionRecord]
    public var programArguments: [SavedProgramArgumentsRecord]
    public var inputDevices: [WorkspaceInputDeviceRecord]

    public init(
        id: String = UUID().uuidString,
        name: String = "Untitled Workspace",
        programs: [SavedProgramDefinitionRecord] = [],
        programArguments: [SavedProgramArgumentsRecord] = [],
        inputDevices: [WorkspaceInputDeviceRecord] = []
    ) {
        self.id = id
        self.name = name
        self.programs = programs
        self.programArguments = programArguments
        self.inputDevices = inputDevices
    }
}

public struct WorkspaceInputDeviceRecord: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: WorkspaceInputDeviceKind
    public var physicalDeviceID: String?
    public var sideTrackRecordingPolicy: WorkspaceSideTrackRecordingPolicy

    public init(
        id: String = UUID().uuidString,
        name: String,
        kind: WorkspaceInputDeviceKind,
        physicalDeviceID: String? = nil,
        sideTrackRecordingPolicy: WorkspaceSideTrackRecordingPolicy = .unspecified
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.physicalDeviceID = physicalDeviceID
        self.sideTrackRecordingPolicy = sideTrackRecordingPolicy
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case physicalDeviceID
        case sideTrackRecordingPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(WorkspaceInputDeviceKind.self, forKey: .kind)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        physicalDeviceID = try container.decodeIfPresent(String.self, forKey: .physicalDeviceID)
        sideTrackRecordingPolicy =
            try container.decodeIfPresent(
                WorkspaceSideTrackRecordingPolicy.self,
                forKey: .sideTrackRecordingPolicy
            ) ?? .unspecified
    }

    public var isMuted: Bool {
        sideTrackRecordingPolicy == .disabled
    }

    public mutating func setMuted(_ isMuted: Bool) {
        sideTrackRecordingPolicy = isMuted ? .disabled : .enabled
    }
}

extension WorkspaceInputDeviceRecord: Identifiable {}

public enum WorkspaceInputDeviceKind: String, CaseIterable, Codable, Equatable, Sendable {
    case unspecified
    case video
    case audio
}

public enum WorkspaceSideTrackRecordingPolicy: String, Codable, Equatable, Sendable {
    case unspecified
    case enabled
    case disabled

    public var recordsSideTrack: Bool {
        switch self {
        case .unspecified, .enabled:
            true
        case .disabled:
            false
        }
    }
}
