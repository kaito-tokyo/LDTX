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
    public var audioChannels: [ProgramAudioChannel]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case programs
        case programArguments
        case audioChannels
    }

    public init(
        id: String = UUID().uuidString,
        name: String = "Untitled Workspace",
        programs: [SavedProgramDefinitionRecord] = [],
        programArguments: [SavedProgramArgumentsRecord] = [],
        audioChannels: [ProgramAudioChannel] = []
    ) {
        self.id = id
        self.name = name
        self.programs = programs
        self.programArguments = programArguments
        self.audioChannels = audioChannels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Workspace"
        programs = try container.decodeIfPresent([SavedProgramDefinitionRecord].self, forKey: .programs) ?? []
        programArguments =
            try container.decodeIfPresent([SavedProgramArgumentsRecord].self, forKey: .programArguments) ?? []
        audioChannels =
            try container.decodeIfPresent([ProgramAudioChannel].self, forKey: .audioChannels) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(programs, forKey: .programs)
        try container.encode(programArguments, forKey: .programArguments)
        try container.encode(audioChannels, forKey: .audioChannels)
    }
}

public typealias WorkspaceInputDeviceRecord = ProgramInputDeviceRecord
public typealias WorkspaceInputDeviceKind = ProgramInputDeviceKind
public typealias WorkspaceSideTrackRecordingPolicy = ProgramSideTrackRecordingPolicy
public typealias WorkspaceInputDeviceBackgroundRemovalPolicy = ProgramInputDeviceBackgroundRemovalPolicy
public typealias WorkspaceInputDeviceColorRangePolicy = ProgramInputDeviceColorRangePolicy
