// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram

/// Verifies that a decoded Workspace can be represented by the application.
///
/// This is deliberately a read boundary only. Saving preserves the exact
/// in-memory Definition and Preferences; it neither repairs nor rejects a
/// user-authored representation.
public enum WorkspaceIntegrityValidator {
    public static func validateForLoading(_ workspace: WorkspaceDefinition) throws {
        try WorkspaceResourceNameValidator.validate(workspace)
        try validateProgramNames(workspace.programs)

        let inputDevicesByID = firstValuesByKey(workspace.inputDevices, key: \.id)

        if let videoPTSMasterInputDeviceID = workspace.outputConfiguration.videoPTSMasterInputDeviceID {
            try requireInputDevice(
                videoPTSMasterInputDeviceID,
                ofKind: .video,
                in: inputDevicesByID,
                reference: "Workspace Output Configuration"
            )
        }

        for component in workspace.videoComponents {
            guard case let .inputCameraDevice(payload) = component.component,
                  let inputDeviceID = payload.inputDeviceID
            else { continue }
            try requireInputDevice(
                inputDeviceID,
                ofKind: .video,
                in: inputDevicesByID,
                reference: "Video Component \(component.name)"
            )
        }

        for channel in workspace.audioChannels {
            guard case let .inputAudioDevice(payload) = channel.component,
                  let inputDeviceID = payload.inputDeviceID
            else { continue }
            try requireInputDevice(
                inputDeviceID,
                ofKind: .audio,
                in: inputDevicesByID,
                reference: "Audio Channel \(channel.name)"
            )
        }

        for vision in workspace.visions {
            if case let .inputDevice(name) = vision.source {
                try requireInputDevice(
                    name,
                    ofKind: .video,
                    in: inputDevicesByID,
                    reference: "Vision \(vision.name)"
                )
            }
        }
    }

    /// Validates the persisted Workspace and its colocated Preferences as one
    /// document. Preference references are meaningful only with the Workspace
    /// Definition they were saved alongside.
    public static func validateForLoading(
        _ workspace: WorkspaceDefinition,
        preferences: WorkspacePreferences
    ) throws {
        try validateForLoading(workspace)
        if let selectedProgramName = preferences.selectedProgramName,
           !workspace.programs.contains(where: { $0.name == selectedProgramName }) {
            throw WorkspaceIntegrityError.missingReference(
                owner: "Workspace Preferences",
                reference: selectedProgramName
            )
        }
        let programNames = Set(workspace.programs.map(\.name))
        let componentNames = Set(workspace.videoComponents.map(\.name))
        let videoInputDeviceNames = Set(
            workspace.inputDevices.lazy
                .filter { $0.kind == .video }
                .map(\.name)
        )
        let videoLayerSourceNames = componentNames.union(videoInputDeviceNames)
        for (programName, layers) in preferences.programPreferences.videoLayersByProgramName {
            guard programNames.contains(programName) else {
                throw WorkspaceIntegrityError.missingReference(
                    owner: "Video Layer Preferences",
                    reference: programName
                )
            }
            for layer in layers where !videoLayerSourceNames.contains(layer.componentName) {
                throw WorkspaceIntegrityError.missingReference(
                    owner: "Video Layers for \(programName)",
                    reference: layer.componentName
                )
            }
        }
    }

    private static func requireInputDevice(
        _ id: String,
        ofKind expectedKind: WorkspaceInputDeviceKind,
        in inputDevicesByID: [String: WorkspaceInputDeviceRecord],
        reference: String
    ) throws {
        guard let inputDevice = inputDevicesByID[id] else {
            throw WorkspaceIntegrityError.missingReference(owner: reference, reference: id)
        }
        guard inputDevice.kind == expectedKind else {
            throw WorkspaceIntegrityError.incompatibleInputDevice(
                owner: reference,
                inputDeviceID: id,
                expectedKind: expectedKind,
                actualKind: inputDevice.kind
            )
        }
    }

    private static func validateProgramNames(_ programs: [SavedProgramDefinitionRecord]) throws {
        var seen = Set<String>()
        for program in programs {
            guard seen.insert(program.name).inserted else {
                throw WorkspaceIntegrityError.duplicateProgramName(program.name)
            }
        }
    }
}

public enum WorkspaceIntegrityError: LocalizedError, Equatable, Sendable {
    case duplicateProgramName(String)
    case missingReference(owner: String, reference: String)
    case incompatibleInputDevice(
        owner: String,
        inputDeviceID: String,
        expectedKind: WorkspaceInputDeviceKind,
        actualKind: WorkspaceInputDeviceKind
    )

    public var errorDescription: String? {
        switch self {
        case let .duplicateProgramName(name):
            "Program name \"\(name)\" is used more than once. Program names must be unique."
        case let .missingReference(owner, reference):
            "\(owner) refers to missing resource \"\(reference)\"."
        case let .incompatibleInputDevice(owner, inputDeviceID, expectedKind, actualKind):
            "\(owner) requires a \(expectedKind.rawValue) input device, but \"\(inputDeviceID)\" is \(actualKind.rawValue)."
        }
    }
}

private func firstValuesByKey<Value>(_ values: [Value], key: (Value) -> String) -> [String: Value] {
    var result: [String: Value] = [:]
    for value in values where result[key(value)] == nil {
        result[key(value)] = value
    }
    return result
}
