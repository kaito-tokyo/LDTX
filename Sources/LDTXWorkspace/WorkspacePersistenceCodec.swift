// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import OSLog
import SwiftProtobuf

private let workspacePersistenceLogger = Logger(
    subsystem: "tokyo.kaito.ldtx",
    category: "workspace-persistence"
)

public enum WorkspacePersistenceCodec {
    public static func encodeWorkspace(_ workspace: WorkspaceDefinition) throws -> Data {
        try workspace.protoMessage.serializedData()
    }

    public static func decodeWorkspace(
        from data: Data,
        preferences: WorkspacePreferences = WorkspacePreferences()
    ) throws -> WorkspaceSnapshot {
        let persisted = try Ldtx_Workspace_V1_Workspace(serializedBytes: data)
        let protobufMigration = try WorkspaceMigrator.migrate(persisted)
        let definition = try protobufMigration.workspace.decodedDomainModel
        let snapshot = WorkspaceMigrator.migrate(
            definition: definition,
            preferences: preferences,
            protobufMigration: protobufMigration
        )
        try WorkspaceIntegrityValidator.validateForLoading(
            snapshot.definition,
            preferences: snapshot.preferences
        )
        return snapshot
    }

    public static func encodeWorkspaceJSON(_ workspace: WorkspaceDefinition) throws -> Data {
        try workspace.protoMessage.jsonUTF8Data()
    }

    public static func decodeWorkspaceJSON(
        from data: Data,
        preferences: WorkspacePreferences = WorkspacePreferences()
    ) throws -> WorkspaceSnapshot {
        let persisted = try Ldtx_Workspace_V1_Workspace(jsonUTF8Data: data)
        let protobufMigration = try WorkspaceMigrator.migrate(persisted)
        let definition = try protobufMigration.workspace.decodedDomainModel
        let snapshot = WorkspaceMigrator.migrate(
            definition: definition,
            preferences: preferences,
            protobufMigration: protobufMigration
        )
        try WorkspaceIntegrityValidator.validateForLoading(
            snapshot.definition,
            preferences: snapshot.preferences
        )
        return snapshot
    }

    public static func encodePreferences(_ preferences: WorkspacePreferences) throws -> Data {
        try preferences.protoMessage.serializedData()
    }

    public static func decodePreferences(from data: Data) throws -> WorkspacePreferences {
        try Ldtx_Workspace_V1_WorkspacePreferences(serializedBytes: data).domainModel
    }

    public static func encodePreferencesJSON(_ preferences: WorkspacePreferences) throws -> Data {
        try preferences.protoMessage.jsonUTF8Data()
    }

}

/// The complete semantic state loaded from one Workspace bundle.
///
/// Definition and Preferences are intentionally kept together because
/// references and migrated values are only meaningful as a consistent pair.
public struct WorkspaceSnapshot: Equatable, Sendable {
    public var definition: WorkspaceDefinition
    public var preferences: WorkspacePreferences

    public init(definition: WorkspaceDefinition, preferences: WorkspacePreferences) {
        self.definition = definition
        self.preferences = preferences
    }
}

private enum WorkspacePersistenceCodecError: Error {
    case missingProgramRecord
    case missingProgramPreferencesRecord
    case unsigned32OutOfRange(String, Int)
}

private extension WorkspaceDefinition {
    var protoMessage: Ldtx_Workspace_V1_Workspace {
        get throws {
            var proto = Ldtx_Workspace_V1_Workspace()
            proto.formatVersion = WorkspaceMigrator.currentFormatVersion
            proto.name = name
            proto.programs = try programs.map { try $0.workspaceProtoMessage }
            proto.inputDevices = try inputDevices.map { try $0.protoMessage() }
            proto.audioChannels = audioChannels.map(\.workspaceProtoMessage)
            proto.visions = visions.map(\.workspaceProtoMessage)
            proto.videoComponents = videoComponents.map(\.workspaceProtoMessage)
            proto.outputConfiguration = outputConfiguration.workspaceProtoMessage
            return proto
        }
    }
}

private extension Ldtx_Workspace_V1_Workspace {
    var decodedDomainModel: WorkspaceDefinition {
        get throws {
            let decodedInputDevices = inputDevices.map(\.domainModel)
            let decodedPrograms = try programs.map { try $0.domainModel }
            let decodedAudioChannels = audioChannels.map(\.domainModel)
            let decodedVisions = visions.map(\.domainModel)
            let decodedVideoComponents = videoComponents.map(\.domainModel)
            let workspace = WorkspaceDefinition(
                name: name,
                programs: decodedPrograms,
                inputDevices: decodedInputDevices,
                audioChannels: decodedAudioChannels,
                visions: decodedVisions,
                videoComponents: decodedVideoComponents,
                outputConfiguration: outputConfiguration.domainModel ?? WorkspaceOutputConfiguration()
            )
            try WorkspaceIntegrityValidator.validateForLoading(workspace)
            return workspace
        }
    }
}

private extension WorkspaceOutputConfiguration {
    var workspaceProtoMessage: Ldtx_Workspace_V1_WorkspaceOutputConfiguration {
        var proto = Ldtx_Workspace_V1_WorkspaceOutputConfiguration()
        proto.canvasWidth = UInt32(clamping: canvasWidth)
        proto.canvasHeight = UInt32(clamping: canvasHeight)
        proto.frameRate = UInt32(clamping: frameRate)
        if let videoPTSMasterInputDeviceID {
            proto.videoPtsMasterInputDeviceID = videoPTSMasterInputDeviceID
        }
        return proto
    }
}

private extension Ldtx_Workspace_V1_WorkspaceOutputConfiguration {
    var domainModel: WorkspaceOutputConfiguration? {
        guard canvasWidth > 0, canvasHeight > 0, frameRate > 0 else { return nil }
        return WorkspaceOutputConfiguration(
            canvasWidth: Int(canvasWidth),
            canvasHeight: Int(canvasHeight),
            frameRate: Int(frameRate),
            videoPTSMasterInputDeviceID: videoPtsMasterInputDeviceID.nilIfEmpty
        )
    }
}

private extension WorkspaceVideoComponentRecord {
    var workspaceProtoMessage: Ldtx_Workspace_V1_VideoComponentRecord {
        var proto = Ldtx_Workspace_V1_VideoComponentRecord()
        proto.name = name
        proto.component = ProgramPersistenceCodec.encodeProgramComponent(component)
        return proto
    }
}

private extension Ldtx_Workspace_V1_VideoComponentRecord {
    var domainModel: WorkspaceVideoComponentRecord {
        return WorkspaceVideoComponentRecord(
            name: name,
            component: ProgramPersistenceCodec.decodeProgramComponent(component)
        )
    }
}

private extension WorkspaceVisionDefinition {
    var workspaceProtoMessage: Ldtx_Workspace_V1_VisionRecord {
        var proto = Ldtx_Workspace_V1_VisionRecord()
        proto.name = name
        switch source {
        case .currentProgramOutput:
            proto.currentProgramOutput = true
        case let .inputDevice(name):
            proto.inputDeviceName = name
        }
        proto.modelRepositoryID = model.repositoryID
        if let revision = model.revision {
            proto.modelRevision = revision
        }
        proto.systemPrompt = systemPrompt
        proto.userPrompt = userPrompt
        proto.updateIntervalSeconds = updateIntervalSeconds ?? 0
        proto.stopsAtNewline = stopsAtNewline
        return proto
    }
}

private extension Ldtx_Workspace_V1_VisionRecord {
    var domainModel: WorkspaceVisionDefinition {
        let source: WorkspaceVisionSource
        switch self.source {
        case let .inputDeviceName(id):
            source = .inputDevice(name: id)
        case .currentProgramOutput, nil:
            source = .currentProgramOutput
        }
        return WorkspaceVisionDefinition(
            name: name.isEmpty ? "Vision" : name,
            source: source,
            model: WorkspaceVisionModel(
                repositoryID: modelRepositoryID.isEmpty
                    ? WorkspaceVisionModel.qwen3VL2BInstruct4Bit.repositoryID
                    : modelRepositoryID,
                revision: hasModelRevision ? modelRevision : nil
            ),
            systemPrompt: systemPrompt.isEmpty
                ? WorkspaceVisionDefinition.defaultSystemPrompt
                : systemPrompt,
            userPrompt: userPrompt.isEmpty ? WorkspaceVisionDefinition.defaultUserPrompt : userPrompt,
            updateIntervalSeconds: updateIntervalSeconds > 0 ? updateIntervalSeconds : nil,
            stopsAtNewline: stopsAtNewline
        )
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

private extension WorkspacePreferences {
    var protoMessage: Ldtx_Workspace_V1_WorkspacePreferences {
        get throws {
            var proto = Ldtx_Workspace_V1_WorkspacePreferences()
            proto.program = try Ldtx_Program_Persistence_V1_ProgramPreferences(
                serializedBytes: ProgramPersistenceCodec.encodeProgramPreferences(programPreferences)
            )
            proto.physicalDeviceIdsByInputDeviceID = physicalDeviceIDsByInputDeviceID
            proto.inputCameraDeviceMappings = inputCameraDeviceMappings
            proto.inputAudioDeviceMappings = inputAudioDeviceMappings
            proto.inputAudioMonitorChannelKeys = inputAudioMonitorChannelKeys.sorted()
            if let selectedProgramName { proto.selectedProgramName = selectedProgramName }
            return proto
        }
    }
}

private extension Ldtx_Workspace_V1_WorkspacePreferences {
    var domainModel: WorkspacePreferences {
        get throws {
            WorkspacePreferences(
                programPreferences: try ProgramPersistenceCodec.decodeProgramPreferences(
                    from: program.serializedData()
                ),
                physicalDeviceIDsByInputDeviceID: physicalDeviceIdsByInputDeviceID,
                inputCameraDeviceMappings: inputCameraDeviceMappings,
                inputAudioDeviceMappings: inputAudioDeviceMappings,
                inputAudioMonitorChannelKeys: Set(inputAudioMonitorChannelKeys),
                selectedProgramName: hasSelectedProgramName ? selectedProgramName : nil
            )
        }
    }
}

private extension WorkspaceInputDeviceRecord {
    func protoMessage() throws -> Ldtx_Workspace_V1_InputDeviceRecord {
        var proto = Ldtx_Workspace_V1_InputDeviceRecord()
        proto.name = name
        proto.kind = kind.protoValue
        proto.backgroundRemovalPolicy = backgroundRemovalPolicy.protoValue
        proto.colorRangePolicy = colorRangePolicy.protoValue
        if let captureWidthOverride {
            proto.captureWidthOverride = try uint32(captureWidthOverride, field: "captureWidthOverride")
        }
        if let captureHeightOverride {
            proto.captureHeightOverride = try uint32(captureHeightOverride, field: "captureHeightOverride")
        }
        if let captureFrameRateOverride {
            proto.captureFrameRateOverride = try uint32(
                captureFrameRateOverride,
                field: "captureFrameRateOverride"
            )
        }
        return proto
    }

    private func uint32(_ value: Int, field: String) throws -> UInt32 {
        guard let converted = UInt32(exactly: value) else {
            throw WorkspacePersistenceCodecError.unsigned32OutOfRange(field, value)
        }
        return converted
    }
}

private extension ProgramAudioChannel {
    var workspaceProtoMessage: Ldtx_Program_V1_ProgramAudioChannel {
        var proto = Ldtx_Program_V1_ProgramAudioChannel()
        proto.name = name
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
        return ProgramAudioChannel(name: name, component: component)
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
            name: name,
            kind: kind.domainModel,
            physicalDeviceID: nil,
            backgroundRemovalPolicy: backgroundRemovalPolicy.domainModel,
            colorRangePolicy: colorRangePolicy.domainModel,
            captureWidthOverride: captureWidthOverride.nilIfZero,
            captureHeightOverride: captureHeightOverride.nilIfZero,
            captureFrameRateOverride: captureFrameRateOverride.nilIfZero
        )
    }
}

private extension UInt32 {
    var nilIfZero: Int? {
        self == 0 ? nil : Int(self)
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
