// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import SwiftProtobuf

public enum WorkspacePersistenceCodec {
    public static func encodeWorkspace(_ workspace: WorkspaceDefinition) throws -> Data {
        try workspace.protoMessage.serializedData()
    }

    public static func decodeWorkspace(from data: Data) throws -> WorkspaceDefinition {
        let proto = try Ldtx_Workspace_V1_Workspace(serializedBytes: data)
        return try proto.domainModel
    }

    public static func encodeWorkspaceJSON(_ workspace: WorkspaceDefinition) throws -> Data {
        try workspace.protoMessage.jsonUTF8Data()
    }

    public static func decodeWorkspaceJSON(from data: Data) throws -> WorkspaceDefinition {
        let proto = try Ldtx_Workspace_V1_Workspace(jsonUTF8Data: data)
        return try proto.domainModel
    }
}

private enum WorkspacePersistenceCodecError: Error {
    case missingProgramRecord
    case missingProgramArgumentsRecord
    case unsigned32OutOfRange(String, Int)
}

private extension WorkspaceDefinition {
    var protoMessage: Ldtx_Workspace_V1_Workspace {
        get throws {
            var proto = Ldtx_Workspace_V1_Workspace()
            proto.id = id
            proto.name = name
            proto.programs = try programs.map { try $0.workspaceProtoMessage }
            proto.programArguments = try programArguments.map { try $0.workspaceProtoMessage }
            proto.audioChannels = audioChannels.map(\.workspaceProtoMessage)
            return proto
        }
    }
}

private extension Ldtx_Workspace_V1_Workspace {
    var domainModel: WorkspaceDefinition {
        get throws {
            let legacyInputDevices = inputDevices.map(\.domainModel)
            let decodedPrograms = try programs.map { try $0.domainModel }
            let decodedAudioChannels = audioChannels.map(\.domainModel)
            let migratedAudioChannels =
                decodedPrograms.first(where: { !$0.composite.audioChannels.isEmpty })?.composite.audioChannels ?? []
            return try WorkspaceDefinition(
                id: id,
                name: name,
                programs: decodedPrograms.map { record in
                    guard record.inputDevices.isEmpty, !legacyInputDevices.isEmpty else {
                        return record
                    }
                    var updated = record
                    updated.inputDevices = legacyInputDevices
                    return updated
                },
                programArguments: programArguments.map { try $0.domainModel },
                audioChannels: decodedAudioChannels.isEmpty ? migratedAudioChannels : decodedAudioChannels
            )
        }
    }
}

private extension SavedProgramDefinitionRecord {
    var workspaceProtoMessage: Ldtx_Workspace_V1_ProgramRecord {
        get throws {
            let data = try ProgramPersistenceCodec.encodeProgramDefinitions([self])
            let library = try Ldtx_Program_Persistence_V1_SavedProgramDefinitionLibrary(serializedBytes: data)
            guard let record = library.records.first else {
                throw WorkspacePersistenceCodecError.missingProgramRecord
            }

            var proto = Ldtx_Workspace_V1_ProgramRecord()
            proto.name = record.name
            proto.canvasWidth = record.canvasWidth
            proto.canvasHeight = record.canvasHeight
            proto.frameRateNumerator = record.frameRateNumerator
            proto.frameRateDenominator = record.frameRateDenominator
            proto.program = record.program
            proto.inputDevices = record.inputDevices
            return proto
        }
    }
}

private extension Ldtx_Workspace_V1_ProgramRecord {
    var domainModel: SavedProgramDefinitionRecord {
        get throws {
            var record = Ldtx_Program_Persistence_V1_SavedProgramDefinitionRecord()
            record.name = name
            record.canvasWidth = canvasWidth
            record.canvasHeight = canvasHeight
            record.frameRateNumerator = frameRateNumerator
            record.frameRateDenominator = frameRateDenominator
            record.program = program
            record.inputDevices = inputDevices

            var library = Ldtx_Program_Persistence_V1_SavedProgramDefinitionLibrary()
            library.records = [record]
            let data = try library.serializedData()
            guard let decoded = try ProgramPersistenceCodec.decodeProgramDefinitions(from: data).first else {
                throw WorkspacePersistenceCodecError.missingProgramRecord
            }
            return decoded
        }
    }
}

private extension SavedProgramArgumentsRecord {
    var workspaceProtoMessage: Ldtx_Workspace_V1_ProgramArgumentsRecord {
        get throws {
            let data = try ProgramPersistenceCodec.encodeProgramArguments([self])
            let library = try Ldtx_Program_Persistence_V1_SavedProgramArgumentsLibrary(serializedBytes: data)
            guard let record = library.records.first else {
                throw WorkspacePersistenceCodecError.missingProgramArgumentsRecord
            }

            var proto = Ldtx_Workspace_V1_ProgramArgumentsRecord()
            proto.name = record.name
            proto.arguments = record.arguments
            return proto
        }
    }
}

private extension Ldtx_Workspace_V1_ProgramArgumentsRecord {
    var domainModel: SavedProgramArgumentsRecord {
        get throws {
            var record = Ldtx_Program_Persistence_V1_SavedProgramArgumentsRecord()
            record.name = name
            record.arguments = arguments

            var library = Ldtx_Program_Persistence_V1_SavedProgramArgumentsLibrary()
            library.records = [record]
            let data = try library.serializedData()
            guard let decoded = try ProgramPersistenceCodec.decodeProgramArguments(from: data).first else {
                throw WorkspacePersistenceCodecError.missingProgramArgumentsRecord
            }
            return decoded
        }
    }
}

private extension WorkspaceInputDeviceRecord {
    var protoMessage: Ldtx_Workspace_V1_InputDeviceRecord {
        var proto = Ldtx_Workspace_V1_InputDeviceRecord()
        proto.id = id
        proto.name = name
        proto.kind = kind.protoValue
        if let physicalDeviceID {
            proto.physicalDeviceID = physicalDeviceID
        }
        proto.sideTrackRecordingPolicy = sideTrackRecordingPolicy.protoValue
        proto.backgroundRemovalPolicy = backgroundRemovalPolicy.protoValue
        proto.colorRangePolicy = colorRangePolicy.protoValue
        return proto
    }
}

private extension ProgramAudioChannel {
    var workspaceProtoMessage: Ldtx_Program_V1_ProgramAudioChannel {
        var proto = Ldtx_Program_V1_ProgramAudioChannel()
        proto.id = id.uuidString.lowercased()
        switch component {
        case let .inputAudioDevice(payload):
            proto.inputAudioDevice = payload.workspaceProtoMessage
        case .silentAudio:
            proto.silentAudio = Ldtx_Program_V1_SilentAudioComponent()
        case .testPatternAudio:
            proto.testPatternAudio = Ldtx_Program_V1_TestPatternAudioComponent()
        }
        return proto
    }
}

private extension Ldtx_Program_V1_ProgramAudioChannel {
    var domainModel: ProgramAudioChannel {
        let component: ProgramAudioChannelComponent
        switch definition {
        case let .inputAudioDevice(payload):
            component = .inputAudioDevice(payload.domainModel)
        case .silentAudio:
            component = .silentAudio
        case .testPatternAudio:
            component = .testPatternAudio
        case nil:
            component = .inputAudioDevice(InputAudioDeviceComponent())
        }
        return ProgramAudioChannel(
            id: UUID(uuidString: id) ?? UUID(),
            component: component
        )
    }
}

private extension InputAudioDeviceComponent {
    var workspaceProtoMessage: Ldtx_Program_V1_InputAudioDeviceComponent {
        var proto = Ldtx_Program_V1_InputAudioDeviceComponent()
        if let inputDeviceID {
            proto.inputDeviceID = inputDeviceID
        }
        return proto
    }
}

private extension Ldtx_Program_V1_InputAudioDeviceComponent {
    var domainModel: InputAudioDeviceComponent {
        InputAudioDeviceComponent(inputDeviceID: inputDeviceID.nilIfEmpty)
    }
}

private extension Ldtx_Workspace_V1_InputDeviceRecord {
    var domainModel: WorkspaceInputDeviceRecord {
        WorkspaceInputDeviceRecord(
            id: id.isEmpty ? UUID().uuidString : id,
            name: name,
            kind: kind.domainModel,
            physicalDeviceID: physicalDeviceID.nilIfEmpty,
            sideTrackRecordingPolicy: sideTrackRecordingPolicy.domainModel,
            backgroundRemovalPolicy: backgroundRemovalPolicy.domainModel,
            colorRangePolicy: colorRangePolicy.domainModel
        )
    }
}

private extension WorkspaceInputDeviceKind {
    var protoValue: Ldtx_Workspace_V1_InputDeviceKind {
        switch self {
        case .unspecified:
            .unspecified
        case .video:
            .video
        case .audio:
            .audio
        }
    }
}

private extension Ldtx_Workspace_V1_InputDeviceKind {
    var domainModel: WorkspaceInputDeviceKind {
        switch self {
        case .unspecified, .UNRECOGNIZED(_):
            .unspecified
        case .video:
            .video
        case .audio:
            .audio
        }
    }
}

private extension WorkspaceSideTrackRecordingPolicy {
    var protoValue: Ldtx_Workspace_V1_SideTrackRecordingPolicy {
        switch self {
        case .unspecified:
            .unspecified
        case .enabled:
            .enabled
        case .disabled:
            .disabled
        }
    }
}

private extension Ldtx_Workspace_V1_SideTrackRecordingPolicy {
    var domainModel: WorkspaceSideTrackRecordingPolicy {
        switch self {
        case .unspecified, .UNRECOGNIZED(_):
            .unspecified
        case .enabled:
            .enabled
        case .disabled:
            .disabled
        }
    }
}

private extension WorkspaceInputDeviceBackgroundRemovalPolicy {
    var protoValue: Ldtx_Workspace_V1_BackgroundRemovalPolicy {
        switch self {
        case .unspecified:
            .unspecified
        case .enabled:
            .enabled
        case .disabled:
            .disabled
        }
    }
}

private extension Ldtx_Workspace_V1_BackgroundRemovalPolicy {
    var domainModel: WorkspaceInputDeviceBackgroundRemovalPolicy {
        switch self {
        case .unspecified, .UNRECOGNIZED(_):
            .unspecified
        case .enabled:
            .enabled
        case .disabled:
            .disabled
        }
    }
}

private extension WorkspaceInputDeviceColorRangePolicy {
    var protoValue: Ldtx_Workspace_V1_ColorRangePolicy {
        switch self {
        case .unspecified:
            .unspecified
        case .videoRange:
            .videoRange
        case .fullRange:
            .fullRange
        }
    }
}

private extension Ldtx_Workspace_V1_ColorRangePolicy {
    var domainModel: WorkspaceInputDeviceColorRangePolicy {
        switch self {
        case .unspecified, .UNRECOGNIZED(_):
            .unspecified
        case .videoRange:
            .videoRange
        case .fullRange:
            .fullRange
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
