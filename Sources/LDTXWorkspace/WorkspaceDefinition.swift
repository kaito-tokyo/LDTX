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
    public var name: String
    public var kind: WorkspaceInputDeviceKind
    public var sideTrackRecordingPolicy: WorkspaceSideTrackRecordingPolicy

    public init(
        name: String,
        kind: WorkspaceInputDeviceKind,
        sideTrackRecordingPolicy: WorkspaceSideTrackRecordingPolicy = .unspecified
    ) {
        self.name = name
        self.kind = kind
        self.sideTrackRecordingPolicy = sideTrackRecordingPolicy
    }
}

public enum WorkspaceInputDeviceKind: String, Codable, Equatable, Sendable {
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
