// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram

public struct WorkspaceDefinition: Codable, Equatable, Sendable {
    public var name: String
    public var programs: [SavedProgramDefinitionRecord]
    public var inputDevices: [WorkspaceInputDeviceRecord]
    public var audioChannels: [ProgramAudioChannel]
    public var visions: [WorkspaceVisionDefinition]
    public var automations: [WorkspaceAutomationDefinition]

    public static func == (lhs: WorkspaceDefinition, rhs: WorkspaceDefinition) -> Bool {
        lhs.name == rhs.name &&
        lhs.programs == rhs.programs &&
        lhs.inputDevices == rhs.inputDevices &&
        lhs.audioChannels == rhs.audioChannels &&
        lhs.visions == rhs.visions &&
        lhs.automations == rhs.automations
    }

    enum CodingKeys: String, CodingKey {
        case name
        case programs
        case inputDevices
        case audioChannels
        case visions
        case automations
    }

    public init(
        name: String = "Untitled Workspace",
        programs: [SavedProgramDefinitionRecord] = [],
        inputDevices: [WorkspaceInputDeviceRecord] = [],
        audioChannels: [ProgramAudioChannel] = [],
        visions: [WorkspaceVisionDefinition] = [],
        automations: [WorkspaceAutomationDefinition] = []
    ) {
        self.name = name
        self.programs = programs
        self.inputDevices = inputDevices
        self.audioChannels = audioChannels
        self.visions = visions
        self.automations = automations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Workspace"
        programs = try container.decodeIfPresent([SavedProgramDefinitionRecord].self, forKey: .programs) ?? []
        inputDevices =
            try container.decodeIfPresent([WorkspaceInputDeviceRecord].self, forKey: .inputDevices) ?? []
        audioChannels =
            try container.decodeIfPresent([ProgramAudioChannel].self, forKey: .audioChannels) ?? []
        visions = try container.decodeIfPresent([WorkspaceVisionDefinition].self, forKey: .visions) ?? []
        automations =
            try container.decodeIfPresent([WorkspaceAutomationDefinition].self, forKey: .automations) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(programs, forKey: .programs)
        try container.encode(inputDevices, forKey: .inputDevices)
        try container.encode(audioChannels, forKey: .audioChannels)
        try container.encode(visions, forKey: .visions)
        try container.encode(automations, forKey: .automations)
    }
}

public extension WorkspaceDefinition {
    mutating func renameInputDevice(
        from oldName: String,
        to newName: String,
        preferences: inout WorkspacePreferences
    ) throws {
        guard let index = inputDevices.firstIndex(where: { $0.name == oldName }) else {
            throw WorkspaceRenameError.resourceNotFound(oldName)
        }
        try validateRename(newName, excluding: oldName)

        var next = self
        var nextPreferences = preferences
        next.inputDevices[index].name = newName
        next.renameInputDeviceReferences(from: oldName, to: newName)
        nextPreferences.programPreferences.renameInputDevice(from: oldName, to: newName)
        if let physicalDeviceID = nextPreferences.physicalDeviceIDsByInputDeviceID.removeValue(forKey: oldName) {
            nextPreferences.physicalDeviceIDsByInputDeviceID[newName] = physicalDeviceID
        }
        self = next
        preferences = nextPreferences
    }

    mutating func renameVision(from oldName: String, to newName: String) throws {
        guard let index = visions.firstIndex(where: { $0.name == oldName }) else {
            throw WorkspaceRenameError.resourceNotFound(oldName)
        }
        try validateRename(newName, excluding: oldName)

        visions[index].name = newName
        for automationIndex in automations.indices {
            for actionIndex in automations[automationIndex].actions.indices {
                if case .analyzeVision(let visionName) = automations[automationIndex].actions[actionIndex],
                   visionName == oldName {
                    automations[automationIndex].actions[actionIndex] = .analyzeVision(visionName: newName)
                }
            }
        }
    }

    mutating func renameAutomation(from oldName: String, to newName: String) throws {
        guard let index = automations.firstIndex(where: { $0.name == oldName }) else {
            throw WorkspaceRenameError.resourceNotFound(oldName)
        }
        try validateRename(newName, excluding: oldName)

        automations[index].name = newName
        for visionIndex in visions.indices
        where visions[visionIndex].postActionAutomationName == oldName {
            visions[visionIndex].postActionAutomationName = newName
        }
    }

    mutating func renameProgram(
        from oldName: String,
        to newName: String,
        preferences: inout WorkspacePreferences
    ) throws {
        guard let index = programs.firstIndex(where: { $0.name == oldName }) else {
            throw WorkspaceRenameError.resourceNotFound(oldName)
        }
        guard !newName.isEmpty else { throw WorkspaceRenameError.emptyName }
        guard oldName == newName || !programs.contains(where: { $0.name == newName }) else {
            throw WorkspaceRenameError.duplicateName(newName)
        }

        programs[index].name = newName
        if preferences.selectedProgramName == oldName {
            preferences.selectedProgramName = newName
        }
    }

    private mutating func renameInputDeviceReferences(from oldName: String, to newName: String) {
        for programIndex in programs.indices {
            for inputIndex in programs[programIndex].inputDevices.indices
            where programs[programIndex].inputDevices[inputIndex].name == oldName {
                programs[programIndex].inputDevices[inputIndex].name = newName
            }
            programs[programIndex].composite.renameInputDevice(from: oldName, to: newName)
        }
        for channelIndex in audioChannels.indices {
            if case .inputAudioDevice(var component) = audioChannels[channelIndex].component,
               component.inputDeviceID == oldName {
                component.inputDeviceID = newName
                audioChannels[channelIndex].component = .inputAudioDevice(component)
            }
        }
        for visionIndex in visions.indices {
            if case .inputDevice(let name) = visions[visionIndex].source, name == oldName {
                visions[visionIndex].source = .inputDevice(name: newName)
            }
        }
        for automationIndex in automations.indices {
            for actionIndex in automations[automationIndex].actions.indices {
                if case .selectInputDevice(let name) = automations[automationIndex].actions[actionIndex],
                   name == oldName {
                    automations[automationIndex].actions[actionIndex] = .selectInputDevice(inputDeviceName: newName)
                }
            }
        }
    }

    private func validateRename(_ newName: String, excluding oldName: String) throws {
        guard !newName.isEmpty else { throw WorkspaceRenameError.emptyName }
        guard WorkspaceResourceNameValidator.isAvailable(
            newName,
            inputDevices: inputDevices,
            visions: visions,
            automations: automations,
            excludingResourceID: oldName
        ) else {
            throw WorkspaceRenameError.duplicateName(newName)
        }
    }
}

public enum WorkspaceRenameError: Error, Equatable, LocalizedError {
    case emptyName
    case duplicateName(String)
    case resourceNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            "Name cannot be empty."
        case .duplicateName(let name):
            "A Workspace resource named '\(name)' already exists."
        case .resourceNotFound(let name):
            "Workspace resource '\(name)' was not found."
        }
    }
}

public typealias WorkspaceInputDeviceRecord = ProgramInputDeviceRecord
public typealias WorkspaceInputDeviceKind = ProgramInputDeviceKind
public typealias WorkspaceInputDeviceBackgroundRemovalPolicy = ProgramInputDeviceBackgroundRemovalPolicy
public typealias WorkspaceInputDeviceColorRangePolicy = ProgramInputDeviceColorRangePolicy
